// SystemProUI.m — systemPro 设置面板（自绘高级 UI，不用 PSListController 模板）
// 设计语言：insetGrouped 卡片 + 彩色图标块 + 自定义开关行 + 编辑值子页
// + 轻点震动反馈 + 原生弹窗提示（无注销按钮：改动即时生效）
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <math.h>
#import "Common.h"    // 开关键名单一来源（-I.. 引入）
#import "Version.h"
// Preferences.framework 私有头（vendored 自 theos/headers，签名与真机对齐）
#import "PBHeaders/PSTableCell.h"
#import "PBHeaders/PSSpecifier.h"
#import "PBHeaders/PSViewController.h"
#import "PBHeaders/PSListController.h"

extern char **environ;
extern int notify_post(const char *name);

#pragma mark - 数据模型
typedef NS_ENUM(NSInteger, SPRowKind) {
    SPRowKindSwitch = 0,
    SPRowKindText,
    SPRowKindButton,
    SPRowKindInfo,
    SPRowKindLink,
    SPRowKindSlider,
};

@interface SPRow : NSObject
@property (nonatomic) SPRowKind kind;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, strong) UIColor *tint;
@property (nonatomic, copy) NSString *defValue;
@property (nonatomic) BOOL numeric;
@property (nonatomic) BOOL destructive;
@property (nonatomic, copy) NSString *actionName;
@property (nonatomic) double minValue;       // SPRowKindSlider
@property (nonatomic) double maxValue;
@end

@implementation SPRow
+ (instancetype)kind:(SPRowKind)kind key:(NSString *)key title:(NSString *)title
            subtitle:(NSString *)subtitle icon:(NSString *)icon tint:(UIColor *)tint {
    SPRow *r = [SPRow new];
    r.kind = kind; r.key = key; r.title = title; r.subtitle = subtitle; r.icon = icon; r.tint = tint;
    return r;
}
@end

@interface SPSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, strong) NSArray<SPRow *> *rows;
@end
@implementation SPSection @end

#pragma mark - 轻量偏好读写（直读直写 plist + Darwin 通知，和插件侧同一套协议）
static NSMutableDictionary *SPPrefsLoad(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SPPreferencesPath()];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
static void SPPrefsWrite(NSString *key, id value) {
    // 路径解析与插件侧同一套（roothide jbroot 镜像 / 标准路径），保证两端指向同一份 plist
    NSString *path = SPPreferencesPath();
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    if (value == nil) [d removeObjectForKey:key];
    else d[key] = value;
    BOOL ok = [d writeToFile:path atomically:YES];
    if (!ok) SPLog(@"prefs write FAILED: %@", path);
    notify_post(SP_NOTIFY_RELOAD);
}

#pragma mark - 通用单元格
@interface SPCell : UITableViewCell
@property (nonatomic, strong) UIView *chip;
@property (nonatomic, strong) UIImageView *rowIcon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) NSLayoutConstraint *titleToToggle;
@property (nonatomic, strong) NSLayoutConstraint *titleToSlider;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
@property (nonatomic, copy) void (^onSlider)(double v);
@property (nonatomic, strong) NSLayoutConstraint *subZero;
@end

@implementation SPCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        // 卡片底色显式指定（insetGrouped 下部分行缺省透明会呈灰）
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

        _chip = [UIView new];
        _chip.layer.cornerRadius = 7.0;
        _chip.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:_chip];

        _rowIcon = [UIImageView new];
        _rowIcon.tintColor = [UIColor whiteColor];
        _rowIcon.contentMode = UIViewContentModeCenter;
        [_chip addSubview:_rowIcon];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        _titleLabel.numberOfLines = 0;
        [self.contentView addSubview:_titleLabel];

        _subLabel = [UILabel new];
        _subLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subLabel.textColor = [UIColor secondaryLabelColor];
        _subLabel.numberOfLines = 0;
        [self.contentView addSubview:_subLabel];

        _toggle = [UISwitch new];
        _toggle.onTintColor = [UIColor colorWithRed:0.36 green:0.34 blue:0.92 alpha:1];
        [_toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_toggle];

        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont systemFontOfSize:15];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        _chevron = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"chevron.right" withConfiguration:
                [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
        _chevron.tintColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:_chevron];

        _slider = [UISlider new];
        _slider.minimumTrackTintColor = _toggle.onTintColor;
        _slider.hidden = YES;
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_slider];
    }
    return self;
}

// ============================================================
// 手工 frame 布局（不用 Auto Layout）
// 原因：insetGrouped + 自适应高度下约束会解不开，开关被挤出卡片右侧，
// 超出 cell 边界后 hitTest 收不到触摸 —— 表现为「布局错乱 + 开关点不开」。
// ============================================================
+ (CGFloat)textHeight:(NSString *)text font:(UIFont *)font width:(CGFloat)width {
    if (!text.length || width <= 0) return 0;
    return ceil([text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                attributes:@{ NSFontAttributeName: font }
                                   context:nil].size.height);
}

// 控制器算行高：给定卡片宽度，返回该行需要的高度
+ (CGFloat)heightForRow:(SPRow *)row cardWidth:(CGFloat)cardWidth {
    CGFloat accessW = 0;
    if (row.kind == SPRowKindSwitch)      accessW = 51.0 + 8.0;
    else if (row.kind == SPRowKindSlider) accessW = 140.0 + 8.0 + 44.0 + 8.0;
    CGFloat textW = MAX(80.0, cardWidth - 16.0 - 26.0 - 12.0 - 16.0 - accessW);
    CGFloat h = [self textHeight:row.title font:[UIFont systemFontOfSize:16] width:textW];
    if (row.subtitle.length) {
        h += 1.0 + [self textHeight:row.subtitle font:[UIFont systemFontOfSize:12] width:textW];
    }
    return MAX(58.0, h + 24.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.contentView.bounds.size.width;
    CGFloat H = self.contentView.bounds.size.height;
    const CGFloat padL = 16.0, padR = 16.0, chipS = 26.0, gap = 12.0;

    // 左侧图标块
    self.chip.frame = CGRectMake(padL, (H - chipS) / 2.0, chipS, chipS);
    self.rowIcon.frame = self.chip.bounds;

    // 右侧控件占位
    CGFloat accessW = 0;
    if (!self.toggle.hidden)      accessW = 51.0 + 8.0;
    else if (!self.slider.hidden) accessW = 140.0 + 8.0 + 44.0 + 8.0;

    CGFloat textX = padL + chipS + gap;
    CGFloat textW = MAX(80.0, W - textX - padR - accessW);

    CGFloat titleH = [SPCell textHeight:self.titleLabel.text font:self.titleLabel.font width:textW];
    CGFloat subH   = self.subLabel.hidden ? 0.0
                     : [SPCell textHeight:self.subLabel.text font:self.subLabel.font width:textW];
    CGFloat totalH = titleH + (subH > 0 ? subH + 1.0 : 0.0);
    CGFloat y = MAX(12.0, (H - totalH) / 2.0);

    self.titleLabel.frame = CGRectMake(textX, y, textW, titleH);
    self.subLabel.frame   = CGRectMake(textX, y + titleH + (subH > 0 ? 1.0 : 0.0), textW, subH);

    // 开关：永远贴在卡片右侧内边距里（不会越界）
    if (!self.toggle.hidden) {
        self.toggle.frame = CGRectMake(W - padR - 51.0, (H - 31.0) / 2.0, 51.0, 31.0);
    }

    // 右侧数值 + 箭头（右对齐）
    CGFloat rightX = W - padR;
    if (!self.chevron.hidden) {
        self.chevron.frame = CGRectMake(rightX - 8.0, (H - 13.0) / 2.0, 8.0, 13.0);
        rightX -= (8.0 + 6.0);
    }
    if (!self.valueLabel.hidden) {
        CGFloat vw = MIN(200.0, MAX(40.0, rightX - textX - 8.0));
        self.valueLabel.frame = CGRectMake(rightX - vw, (H - 20.0) / 2.0, vw, 20.0);
        rightX -= (vw + 8.0);
    }
    if (!self.slider.hidden) {
        self.slider.frame = CGRectMake(MAX(textX, rightX - 140.0), (H - 31.0) / 2.0, 140.0, 31.0);
    }
}

- (void)toggleChanged:(UISwitch *)sw {
    if (self.onToggle) self.onToggle(sw.isOn);
}
- (void)sliderChanged:(UISlider *)s {
    self.valueLabel.text = [NSString stringWithFormat:@"%.0f", s.value];
    if (self.onSlider) self.onSlider(round(s.value));
}
- (void)configureWithRow:(SPRow *)row value:(id)value {
    self.chip.backgroundColor = row.tint;
    self.rowIcon.image = [UIImage systemImageNamed:row.icon withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
    self.titleLabel.text = row.title;
    self.subLabel.text = row.subtitle;
    BOOL hasSub = (row.subtitle.length > 0);
    self.subLabel.hidden = !hasSub;
    self.subZero.active = !hasSub;

    BOOL isSwitch = (row.kind == SPRowKindSwitch);
    BOOL isText   = (row.kind == SPRowKindText);
    BOOL isInfo   = (row.kind == SPRowKindInfo);
    BOOL isButton = (row.kind == SPRowKindButton);
    BOOL isLink   = (row.kind == SPRowKindLink);
    BOOL isSlider = (row.kind == SPRowKindSlider);

    self.toggle.hidden = !isSwitch;
    self.valueLabel.hidden = !(isText || isInfo || isSlider);
    self.chevron.hidden = !(isText || isLink);
    self.slider.hidden = !isSlider;
    self.titleToToggle.active = !isSlider;
    self.titleToSlider.active = isSlider;
    if (isSlider) {
        self.slider.minimumValue = (float)row.minValue;
        self.slider.maximumValue = (float)row.maxValue;
        double v = value ? [value doubleValue] : [row.defValue doubleValue];
        self.slider.value = (float)v;
        self.valueLabel.text = [NSString stringWithFormat:@"%.0f", v];
    }
    self.selectionStyle = (isText || isButton || isLink) ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    self.titleLabel.textColor = row.destructive ? [UIColor systemRedColor] : [UIColor labelColor];

    if (isSwitch) {
        self.toggle.on = [value boolValue];
    } else if (isText) {
        NSString *s = value ? [value description] : (row.defValue ?: @"");
        self.valueLabel.text = s.length ? s : @"默认";
    } else if (isInfo) {
        self.valueLabel.text = [value description];
    }
}
@end

#pragma mark - 编辑值子页
@interface SPEditController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) SPRow *row;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, copy) void (^onSaved)(NSString *newValue);
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) NSString *initialValue;
@end

@implementation SPEditController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = self.row.title;

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *cap = [UILabel new];
    cap.text = self.row.subtitle.length ? self.row.subtitle : @"留空则恢复默认值";
    cap.font = [UIFont systemFontOfSize:12];
    cap.textColor = [UIColor secondaryLabelColor];
    cap.numberOfLines = 0;
    cap.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:cap];

    self.field = [UITextField new];
    self.field.translatesAutoresizingMaskIntoConstraints = NO;
    self.field.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
    self.field.placeholder = self.row.defValue ?: @"";
    self.field.text = self.initialValue.length ? self.initialValue : @"";
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    if (self.row.numeric) self.field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.field.delegate = self;
    [card addSubview:self.field];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [card.heightAnchor constraintEqualToConstant:52],
        [self.field.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.field.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [cap.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:10],
        [cap.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [cap.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                         target:self action:@selector(save)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.field becomeFirstResponder];
}

- (void)save {
    NSString *v = [self.field.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.row.numeric && v.length) {
        NSScanner *sc = [NSScanner scannerWithString:v];
        double d = 0;
        if (![sc scanDouble:&d] || !sc.isAtEnd) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"数值无效"
                message:@"请输入数字（可带小数）。" preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
    }
    if (self.onSaved) self.onSaved(v.length ? v : nil);
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self save];
    return YES;
}
@end

#pragma mark - 主控制器
// 基类直接来自 vendored 的 Preferences 私有头（PBHeaders/PSListController.h），
// 与 SystemX 同款：面板控制器必须挂在 PSListController 上。
// 表格用框架原生 specifier 模型驱动（分节 = group specifier，行 = cell specifier），
// 只重写 cellForRow 自定义样式 —— 这是社区验证过的标准姿势；
// 切记不要自己接管 numberOfSections/numberOfRows（会撞 PSListController 内部缓存，iOS 16 直接抛 NSRangeException）。
@interface SystemProRootController : PSListController
@property (nonatomic, strong) UITableView *contentTable;
@property (nonatomic, strong) NSMutableArray<SPSection *> *model;
@property (nonatomic, strong) NSMutableDictionary *prefs;
@end

@implementation SystemProRootController

// ⚠️ 默认必须显式设为 -1（首页）：NSInteger 默认 0 会直接落进"状态栏"子页，
// 导致首页分页入口永远不可见（"其他功能看不见"的根因）。
- (instancetype)init {
    self = [super init];
    return self;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    return self;
}

#pragma mark specifier 模型

- (void)spEnsureModel { if (!self.model) [self buildModel]; }

- (NSMutableArray *)specifiers {
    [self spEnsureModel];
    if (!_specifiers) _specifiers = [self spBuildSpecifiers];
    return _specifiers;
}

- (NSMutableArray *)spBuildSpecifiers {
    NSMutableArray *arr = [NSMutableArray array];
    for (SPSection *sec in self.model) {
        // group specifier：优先用工厂方法，缺失时手工构造（都对 iOS 16 安全）
        PSSpecifier *g = nil;
        if ([PSSpecifier respondsToSelector:@selector(groupSpecifierWithName:)]) {
            g = [PSSpecifier groupSpecifierWithName:sec.title];
        } else {
            g = [[PSSpecifier alloc] init];
            [g setName:sec.title];
            [g setCellType:PSGroupCell];
            [g setProperty:sec.title forKey:@"label"];
        }
        if (sec.footer.length) [g setProperty:sec.footer forKey:@"footerText"];
        [arr addObject:g];

        for (SPRow *row in sec.rows) {
            PSCellType ct = PSStaticTextCell;
            if (row.kind == SPRowKindSwitch)      ct = PSSwitchCell;
            else if (row.kind == SPRowKindButton) ct = PSButtonCell;
            else if (row.kind == SPRowKindText)   ct = PSLinkCell;
            else if (row.kind == SPRowKindLink)   ct = PSLinkCell;

            PSSpecifier *sp = nil;
            if ([PSSpecifier respondsToSelector:@selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:)]) {
                sp = [PSSpecifier preferenceSpecifierNamed:row.title
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:nil
                                                      cell:ct
                                                      edit:nil];
            } else {
                sp = [[PSSpecifier alloc] init];
                [sp setName:row.title];
                [sp setCellType:ct];
            }
            [sp setProperty:row forKey:@"spRow"];
            if (row.key) [sp setProperty:row.key forKey:@"key"];
            [arr addObject:sp];
        }
    }
    return arr;
}

// 行数据直接走我们的模型（与 specifier 数组逐一对应；不依赖 iOS 16 上未验证的选择器）
- (SPRow *)spRowAtIndexPath:(NSIndexPath *)indexPath {
    [self spEnsureModel];
    if (indexPath.section >= (NSInteger)self.model.count) return nil;
    SPSection *sec = self.model[indexPath.section];
    if (indexPath.row >= (NSInteger)sec.rows.count) return nil;
    return sec.rows[indexPath.row];
}

- (UITableViewStyle)tableViewStyle {
    return UITableViewStyleInsetGrouped;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self spEnsureModel];
    self.title = @"systemPro";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.prefs = SPPrefsLoad();

    // 只使用 iOS 16 上确有实现的选择器：PSListController 的 -table（SystemX 同款、实证可用）。
    // 绝不要再碰 -tableView（iOS 16 未实现 → unrecognized selector 闪退）。
    UITableView *tv = self.table;
    if (!tv && [self.view isKindOfClass:[UITableView class]]) tv = (UITableView *)self.view;
    self.contentTable = tv;
    if (tv) tv.backgroundColor = [UIColor systemGroupedBackgroundColor];
    if (tv) {
        // 极简头部：只留插件标题 + 版本号（砍掉大卡片）
        UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 78)];
        UILabel *t = [UILabel new];
        t.text = @"systemPro";
        t.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
        t.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *vv = [UILabel new];
        vv.text = [NSString stringWithFormat:@"v%@", SP_VERSION];
        vv.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        vv.textColor = [UIColor secondaryLabelColor];
        vv.translatesAutoresizingMaskIntoConstraints = NO;
        [hdr addSubview:t];
        [hdr addSubview:vv];
        [NSLayoutConstraint activateConstraints:@[
            [t.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor constant:24],
            [t.topAnchor constraintEqualToAnchor:hdr.topAnchor constant:10],
            [vv.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
            [vv.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:2],
        ]];
        tv.tableHeaderView = hdr;
    }
}

// 自定义读值/写值：直接读写我们的 plist + Darwin 通知（绕开 cfprefsd 缓存）
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return nil;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SPPreferencesPath()];
    return d[key];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    SPPrefsWrite(key, value);
    self.prefs = SPPrefsLoad();
}

// 行高：手工按文本算（配合 SPCell 的 frame 布局；不用 UITableViewAutomaticDimension，
// 避免 insetGrouped 下自适应高度与约束冲突导致开关越界/点不到）
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPRow *row = [self spRowAtIndexPath:indexPath];
    if (!row) return 44.0;
    // insetGrouped 卡片宽度 = 表宽 - 左右内边距（取 40 保守值，宁可略高不裁字）
    CGFloat cardW = MAX(200.0, tableView.bounds.size.width - 40.0);
    return [SPCell heightForRow:row cardWidth:cardW];
}
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.prefs = SPPrefsLoad();
    [self.contentTable reloadData];
}

#pragma mark 模型
- (SPSection *)section:(NSString *)title footer:(NSString *)footer rows:(NSArray *)rows {
    SPSection *s = [SPSection new];
    s.title = title; s.footer = footer; s.rows = rows;
    return s;
}
- (SPRow *)sw:(NSString *)key title:(NSString *)t sub:(NSString *)sub icon:(NSString *)icon tint:(UIColor *)tint {
    SPRow *r = [SPRow kind:SPRowKindSwitch key:key title:t subtitle:sub icon:icon tint:tint];
    return r;
}
- (SPRow *)tx:(NSString *)key title:(NSString *)t icon:(NSString *)icon def:(NSString *)def numeric:(BOOL)num {
    SPRow *r = [SPRow kind:SPRowKindText key:key title:t subtitle:nil icon:icon tint:[UIColor systemGrayColor]];
    r.defValue = def; r.numeric = num;
    return r;
}
- (void)buildModel {
    UIColor *indigo = [UIColor colorWithRed:0.36 green:0.34 blue:0.92 alpha:1];
    UIColor *blue   = [UIColor systemBlueColor];
    UIColor *green  = [UIColor systemGreenColor];
    UIColor *teal   = [UIColor systemTealColor];
    UIColor *purple = [UIColor systemPurpleColor];
    UIColor *red    = [UIColor systemRedColor];

    SPSection *main = [self section:@""
        footer:@"全部功能只注入 SpringBoard，改动即时生效。"
        rows:@[
            [self sw:kNoLockAfterRespring title:@"注销不锁屏" sub:@"注销/重启后直接进入桌面，不回锁屏" icon:@"lock.open.fill" tint:green],
            [self sw:kDisableHomeScreenLongPress title:@"长按桌面禁用" sub:@"长按不进编辑模式：不抖动、无动作（3D Touch 保留）" icon:@"hand.point.up.left.fill" tint:indigo],
            [self sw:kColorizeVPNStatusBar title:@"VPN 上色" sub:@"VPN 连接时 VPN/WiFi/蜂窝变为 #A7C6FF，并隐藏原版 VPN 图标" icon:@"shield.lefthalf.filled" tint:blue],
            [self sw:kHideVPNFlyInAnimation title:@"VPN 图标不飞入" sub:@"VPN 图标瞬间出现，不播滑入动画" icon:@"bolt.slash.fill" tint:teal],
            [self tx:kFakeBatteryPercent title:@"伪装电量（1-100，0=关）" icon:@"battery.75" def:@"0" numeric:YES],
            [self sw:kRunIndicatorEnabled title:@"APP 运行指示点" sub:@"运行中的 App，图标名称替换为 #A7C6FF 圆点" icon:@"circlebadge.fill" tint:purple],
            [self sw:kHideIconDeleteMenu title:@"长按菜单隐藏删除" sub:@"长按 App 的菜单里去掉「删除 App」，其它项保留" icon:@"trash.slash.fill" tint:red],
        ]];

    SPRow *au = [SPRow kind:SPRowKindInfo key:nil title:@"作者" subtitle:nil icon:@"person" tint:[UIColor systemGrayColor]];
    au.defValue = @"D";
    SPSection *about = [self section:@"关于" footer:nil rows:@[au]];

    self.model = [@[main, about] mutableCopy];
}

#pragma mark - 表格数据源 / 交互（分节与行序由框架 specifier 模型负责）

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SPRow *row = [self spRowAtIndexPath:indexPath];
    if (!row) {
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    }
    SPCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[SPCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }
    id value = (row.kind == SPRowKindInfo) ? row.defValue : self.prefs[row.key];
    [cell configureWithRow:row value:value];
    __weak typeof(self) weakSelf = self;
    if (row.kind == SPRowKindSwitch) {
        cell.onToggle = ^(BOOL on) {
            [weakSelf setPref:row.key value:@(on) row:row];
        };
    } else {
        cell.onToggle = nil;
    }
    if (row.kind == SPRowKindSlider) {
        cell.onSlider = ^(double v) {
            [weakSelf setPref:row.key value:[NSString stringWithFormat:@"%.0f", v] row:row];
        };
    } else {
        cell.onSlider = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SPRow *row = [self spRowAtIndexPath:indexPath];
    if (!row) return;
    if (row.kind == SPRowKindSwitch) {
        return; // 只允许点开关本体切换；点文字/行不再切换
    } else if (row.kind == SPRowKindText) {
        SPEditController *e = [SPEditController new];
        e.row = row;
        id cur = self.prefs[row.key];
        e.initialValue = cur ? [cur description] : @"";
        __weak typeof(self) weakSelf = self;
        e.onSaved = ^(NSString *v) {
            [weakSelf setPref:row.key value:v row:row];
        };
        [self.navigationController pushViewController:e animated:YES];
    }
}

#pragma mark - 写值 / 反馈
- (void)setPref:(NSString *)key value:(id)value row:(SPRow *)row {
    SPPrefsWrite(key, value);
    if (value == nil) [self.prefs removeObjectForKey:key];
    else self.prefs[key] = value;

    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];

    if (row.kind != SPRowKindSlider) [self.contentTable reloadData]; // 拖动滑块时不整表刷新
}

// 原生弹窗提示（替代自绘 toast）
- (void)showToast:(NSString *)text {
    if (self.presentedViewController) return; // 避免重复 present
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                              message:text
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 注销（二次确认 + 多路降级 + 失败提示）
// 收集所有可能藏工具的 bin 目录：rootless /var/jb、老式 /usr、roothide jbroot(.jbroot-*)
#pragma mark - 恢复默认（二次确认）
@end
