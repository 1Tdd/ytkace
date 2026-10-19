#import "MediaActionSheet.h"
#include <cmath>

@implementation YTKACEMediaAction
+ (instancetype)action:(NSString *)identifier title:(NSString *)title
                symbol:(NSString *)symbol handler:(dispatch_block_t)handler {
    YTKACEMediaAction *action = [self new];
    action.identifier = identifier;
    action.title = title;
    action.symbol = symbol;
    action.children = @[];
    action.enabled = YES;
    action.dismissesSheet = YES;
    action.handler = handler;
    return action;
}
+ (instancetype)group:(NSString *)identifier title:(NSString *)title
               symbol:(NSString *)symbol children:(NSArray<YTKACEMediaAction *> *)children {
    YTKACEMediaAction *action = [self action:identifier title:title symbol:symbol handler:nil];
    action.children = children;
    action.dismissesSheet = NO;
    return action;
}
@end

@interface YTKACEMediaActionSheet () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UILabel *headingLabel;
@property(nonatomic, strong) NSMutableSet<NSString *> *expandedActions;
@property(nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *visibleSections;
@property(nonatomic, assign) CGFloat contentHeight;
@end

@implementation YTKACEMediaActionSheet
- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _heading = @"";
        _actionSections = @[];
        _expandedActions = [NSMutableSet set];
        _contentHeight = 380;
        self.modalPresentationStyle = UIModalPresentationPageSheet;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    UIVisualEffectView *background = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    background.frame = self.view.bounds;
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:background];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 54, 0, 0);
    self.tableView.contentInset = UIEdgeInsetsMake(8, 0, 20, 0);
    [self.view addSubview:self.tableView];
    self.headingLabel = [UILabel new];
    self.headingLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.headingLabel.adjustsFontForContentSizeCategory = YES;
    self.headingLabel.textColor = UIColor.secondaryLabelColor;
    self.headingLabel.numberOfLines = 2;
    self.headingLabel.text = self.heading;
    [self configureDetents];
    [self reloadActions];
}

- (void)configureDetents {
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.prefersGrabberVisible = YES;
    sheet.preferredCornerRadius = @24;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    sheet.prefersEdgeAttachedInCompactHeight = YES;
    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = YES;
    self.preferredContentSize = CGSizeMake(460, self.contentHeight);
    if (@available(iOS 16.0, *)) {
        __weak YTKACEMediaActionSheet *weakSelf = self;
        UISheetPresentationControllerDetent *content =
            [UISheetPresentationControllerDetent customDetentWithIdentifier:@"ytkace.media.content"
                resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                    return MIN(context.maximumDetentValue, MAX(220, weakSelf.contentHeight));
                }];
        sheet.detents = @[content, UISheetPresentationControllerDetent.largeDetent];
        sheet.selectedDetentIdentifier = @"ytkace.media.content";
    } else {
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
    }
}

- (void)setHeading:(NSString *)heading {
    _heading = [heading copy] ?: @"";
    self.headingLabel.text = _heading;
    if (self.isViewLoaded) [self.view setNeedsLayout];
}

- (void)setActionSections:(NSArray<NSArray<YTKACEMediaAction *> *> *)sections {
    _actionSections = [sections copy];
    if (self.isViewLoaded) [self reloadActions];
}

- (void)setExpanded:(BOOL)expanded forAction:(NSString *)identifier {
    if (expanded) [self.expandedActions addObject:identifier];
    else [self.expandedActions removeObject:identifier];
    if (self.isViewLoaded) [self reloadActions];
}

- (void)appendActions:(NSArray<YTKACEMediaAction *> *)actions
               depth:(NSUInteger)depth toRows:(NSMutableArray *)rows {
    for (YTKACEMediaAction *action in actions) {
        [rows addObject:@{@"action": action, @"depth": @(depth)}];
        if (depth < 6 && [self.expandedActions containsObject:action.identifier]) {
            [self appendActions:action.children depth:depth + 1 toRows:rows];
        }
    }
}

- (void)reloadActions {
    NSMutableArray *sections = [NSMutableArray array];
    for (NSArray *actions in self.actionSections) {
        NSMutableArray *rows = [NSMutableArray array];
        [self appendActions:actions depth:0 toRows:rows];
        if (rows.count) [sections addObject:rows];
    }
    self.visibleSections = sections;
    CGPoint offset = self.tableView.contentOffset;
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    if (offset.y > 0) {
        offset.y = MIN(offset.y, MAX(0, self.tableView.contentSize.height - self.tableView.bounds.size.height));
        self.tableView.contentOffset = offset;
    }
    [self.view setNeedsLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) return;
    CGSize titleSize = [self.headingLabel sizeThatFits:CGSizeMake(MAX(0, width - 64), CGFLOAT_MAX)];
    CGFloat headerHeight = self.heading.length ? titleSize.height + 32 : 8;
    UIView *header = self.tableView.tableHeaderView;
    if (header == nil || fabs(header.frame.size.width - width) > 1 ||
        fabs(header.frame.size.height - headerHeight) > 1) {
        if (header == nil) header = [UIView new];
        header.frame = CGRectMake(0, 0, width, headerHeight);
        self.headingLabel.frame = CGRectMake(32, 16, width - 64, titleSize.height);
        [header addSubview:self.headingLabel];
        self.tableView.tableHeaderView = header;
    }
    CGFloat height = self.tableView.contentSize.height + 48 + self.view.safeAreaInsets.bottom;
    if (fabs(height - self.contentHeight) > 1) {
        self.contentHeight = height;
        if (@available(iOS 16.0, *)) {
            [self.sheetPresentationController animateChanges:^{
                [self.sheetPresentationController invalidateDetents];
            }];
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.visibleSections.count;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return self.visibleSections[section].count;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 0.01 : 20;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return 0.01;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.visibleSections[indexPath.section][indexPath.row];
    YTKACEMediaAction *action = row[@"action"];
    NSUInteger depth = [row[@"depth"] unsignedIntegerValue];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:1 alpha:0.055];
    cell.accessibilityIdentifier = action.identifier;
    if (action.customView != nil) {
        UIView *custom = action.customView;
        custom.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:custom];
        [NSLayoutConstraint activateConstraints:@[
            [custom.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [custom.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            [custom.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [custom.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
            [custom.heightAnchor constraintGreaterThanOrEqualToConstant:34]
        ]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UIListContentConfiguration *config = [UIListContentConfiguration valueCellConfiguration];
    config.text = action.title;
    config.secondaryText = action.detail;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.numberOfLines = 2;
    config.textProperties.color = depth ? UIColor.secondaryLabelColor : UIColor.labelColor;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.secondaryTextProperties.numberOfLines = 2;
    config.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14, depth ? 54 + (depth - 1) * 22 : 16, 14, 16);
    if (action.symbol.length) {
        config.image = [UIImage systemImageNamed:action.symbol];
        config.imageProperties.tintColor = UIColor.labelColor;
        config.imageProperties.maximumSize = CGSizeMake(24, 24);
        config.imageToTextPadding = 14;
    }
    cell.contentConfiguration = config;
    NSString *accessory = action.children.count
        ? ([self.expandedActions containsObject:action.identifier] ? @"chevron.up" : @"chevron.down")
        : (action.selected ? @"checkmark" : nil);
    if (accessory != nil) {
        UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:accessory]];
        image.tintColor = action.selected && !action.children.count
            ? [UIColor colorWithRed:0.73 green:0.43 blue:0.91 alpha:1] : UIColor.tertiaryLabelColor;
        image.contentMode = UIViewContentModeScaleAspectFit;
        image.frame = CGRectMake(0, 0, 20, 20);
        cell.accessoryView = image;
    }
    cell.contentView.alpha = action.enabled ? 1 : 0.4;
    cell.accessoryView.alpha = action.enabled ? 1 : 0.4;
    cell.accessibilityTraits = (action.handler || action.children.count ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText) | (action.selected ? UIAccessibilityTraitSelected : 0) |
        (action.enabled ? 0 : UIAccessibilityTraitNotEnabled);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    YTKACEMediaAction *action = self.visibleSections[indexPath.section][indexPath.row][@"action"];
    if (!action.enabled || action.customView != nil) return;
    if (action.children.count) {
        [self setExpanded:![self.expandedActions containsObject:action.identifier] forAction:action.identifier];
    } else if (action.handler != nil) {
        dispatch_block_t handler = action.handler;
        if (action.dismissesSheet) [self dismissViewControllerAnimated:YES completion:^{
            // Keep the menu's action context alive until the dismissal finishes.
            (void)self.actionSections;
            handler();
        }];
        else handler();
    }
}
@end
