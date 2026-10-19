#import "PostTranslation.h"

NSArray<NSString *> *YTKACETranslationChunks(NSString *text, NSUInteger limit) {
    if (!text.length || !limit) return @[];
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < text.length) {
        NSRange range = [text rangeOfComposedCharacterSequencesForRange:
            NSMakeRange(offset, MIN(limit, text.length - offset))];
        NSUInteger end = NSMaxRange(range);
        if (end < text.length) {
            NSRange search = NSMakeRange(offset + range.length / 2, range.length - range.length / 2);
            NSRange space = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet
                options:NSBackwardsSearch range:search];
            if (space.location != NSNotFound) end = NSMaxRange(space);
        }
        [parts addObject:[text substringWithRange:NSMakeRange(offset, end - offset)]];
        offset = end;
    }
    return parts;
}

NSString *YTKACETranslationResponse(NSData *data) {
    if (!data.length || data.length > 1024 * 1024) return nil;
    id response = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![response isKindOfClass:NSArray.class] || ![response count]) return nil;
    id segments = [response objectAtIndex:0];
    if (![segments isKindOfClass:NSArray.class]) return nil;
    NSMutableString *text = [NSMutableString string];
    for (id segment in segments) {
        if (![segment isKindOfClass:NSArray.class] || ![segment count] || ![[segment objectAtIndex:0] isKindOfClass:NSString.class]) return nil;
        [text appendString:[segment objectAtIndex:0]];
    }
    return text.length ? text : nil;
}

#ifndef YTKACE_TRANSLATION_TEST
#import "../../Runtime/Localization.h"
#import "../../UI/MediaExport.h"
#import "../../UI/Notice.h"

@interface YTKACEPostTranslator : UITableViewController
@property(nonatomic, copy) NSString *sourceText;
@property(nonatomic, copy) NSString *sourceLanguage;
@property(nonatomic, copy) NSString *targetLanguage;
@property(nonatomic, copy) NSString *translation;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, copy) NSArray<NSString *> *parts;
@property(nonatomic, strong) NSMutableString *collected;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) BOOL translating;
@end

@implementation YTKACEPostTranslator
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTKACELocalized(@"Translate post");
    self.sourceLanguage = @"auto";
    NSString *preferred = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject;
    self.targetLanguage = preferred.length ? preferred : @"en";
    self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
        style:UIBarButtonItemStylePlain target:self action:@selector(copyTranslation)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = YTKACELocalized(@"Copy translation");
    [self translate];
}
- (void)dealloc { [_task cancel]; [_session invalidateAndCancel]; }
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || self.isBeingDismissed) [self stop];
}
- (void)stop { self.generation++; [self.task cancel]; self.task = nil; self.translating = NO; }
- (void)close { [self stop]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyTranslation {
    if (!self.translation.length || self.translating) return;
    UIPasteboard.generalPasteboard.string = self.translation;
    YTKACEShowNotice(YTKACELocalized(@"Text copied"));
}
- (NSString *)languageName:(NSString *)code {
    if ([code isEqual:@"auto"]) return YTKACELocalized(@"Detect language");
    return [NSLocale.currentLocale localizedStringForIdentifier:code] ?: code;
}
- (NSArray<NSString *> *)languages {
    NSMutableOrderedSet *codes = [NSMutableOrderedSet orderedSetWithArray:
        @[@"en", @"it", @"es", @"fr", @"de", @"pt", @"ru", @"uk", @"ar", @"ja", @"ko", @"zh-CN", @"zh-TW", @"hi", @"bn", @"tr", @"nl", @"pl", @"sv", @"da", @"fi", @"no", @"el", @"cs", @"ro", @"hu", @"he", @"id", @"vi", @"th", @"fa", @"ur", @"ta", @"te", @"ms", @"fil", @"sw"]];
    [codes addObject:self.targetLanguage];
    return [codes.array sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[self languageName:a] localizedCaseInsensitiveCompare:[self languageName:b]];
    }];
}
- (UIMenu *)languageMenu:(BOOL)source {
    NSMutableArray *actions = [NSMutableArray array];
    NSArray *codes = source ? [@[@"auto"] arrayByAddingObjectsFromArray:[self languages]] : [self languages];
    __weak YTKACEPostTranslator *weakSelf = self;
    for (NSString *code in codes) {
        UIAction *action = [UIAction actionWithTitle:[self languageName:code] image:nil identifier:code
            handler:^(__unused UIAction *sender) {
                if (source) weakSelf.sourceLanguage = code; else weakSelf.targetLanguage = code;
                [weakSelf translate];
            }];
        action.state = [code isEqual:source ? self.sourceLanguage : self.targetLanguage] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithChildren:actions];
}
- (void)refresh {
    self.navigationItem.rightBarButtonItem.enabled = self.translation.length && !self.translating;
    [self.tableView reloadData];
}
- (void)translate {
    [self stop];
    self.translation = nil;
    if (!self.sourceText.length || self.sourceText.length > 65536) {
        self.status = YTKACELocalized(@"This text is too long to translate."); [self refresh]; return;
    }
    self.parts = YTKACETranslationChunks(self.sourceText, 1000);
    self.collected = [NSMutableString string];
    self.translating = YES;
    self.status = YTKACELocalized(@"Translating...");
    [self refresh];
    [self requestPart:0 generation:self.generation];
}
- (void)requestPart:(NSUInteger)index generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (index == self.parts.count) {
        self.translation = self.collected; self.status = nil; self.translating = NO; self.task = nil;
        [self refresh]; return;
    }
    NSURLComponents *URL = [NSURLComponents componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    URL.queryItems = @[[NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:self.sourceLanguage],
        [NSURLQueryItem queryItemWithName:@"tl" value:self.targetLanguage],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
        [NSURLQueryItem queryItemWithName:@"q" value:self.parts[index]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL.URL];
    request.timeoutInterval = 20;
    __weak YTKACEPostTranslator *weakSelf = self;
    self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger http = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *translated = !error && http == 200 ? YTKACETranslationResponse(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTKACEPostTranslator *controller = weakSelf;
            if (!controller || generation != controller.generation) return;
            if (!translated.length) {
                controller.translating = NO; controller.task = nil;
                controller.status = YTKACELocalized(http == 429 ? @"The translator is busy. Try again in a few minutes." : @"Translation unavailable. Tap to retry.");
                [controller refresh]; return;
            }
            [controller.collected appendString:translated];
            // Preserve a chunk's trailing paragraph/word separator.
            NSString *part = controller.parts[index];
            NSUInteger end = part.length;
            while (end && [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[part characterAtIndex:end - 1]]) end--;
            if (end < part.length && ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[translated characterAtIndex:translated.length - 1]])
                [controller.collected appendString:[part substringFromIndex:end]];
            [controller requestPart:index + 1 generation:generation];
        });
    }];
    [self.task resume];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return YTKACELocalized(section == 0 ? @"Language" : (section == 1 ? @"Original text" : @"Translation"));
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (path.section == 0) {
        BOOL source = path.row == 0;
        cell.textLabel.text = YTKACELocalized(source ? @"From" : @"To");
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:[self languageName:source ? self.sourceLanguage : self.targetLanguage] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        button.accessibilityLabel = cell.textLabel.text;
        button.menu = [self languageMenu:source]; button.showsMenuAsPrimaryAction = YES;
        [button sizeToFit]; cell.accessoryView = button;
    } else if (path.section == 2 && !self.translation.length) {
        cell.textLabel.text = self.status;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        if (self.translating) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating]; cell.accessoryView = spinner;
        } else cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        UITextView *text = [UITextView new];
        text.text = path.section == 1 ? self.sourceText : self.translation;
        text.editable = NO; text.selectable = YES; text.scrollEnabled = NO;
        text.backgroundColor = UIColor.clearColor;
        text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        text.adjustsFontForContentSizeCategory = YES;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [text.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [text.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [text.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            [text.heightAnchor constraintGreaterThanOrEqualToConstant:60]]];
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2 && !self.translating && !self.translation.length) [self translate];
}
@end

void YTKACEPresentPostTranslation(NSString *text, UIView *sourceView) {
    UIViewController *presenter = YTKACEMediaPresenter(sourceView);
    if (!text.length || !presenter) return;
    YTKACEPostTranslator *translator = [[YTKACEPostTranslator alloc] initWithStyle:UITableViewStyleInsetGrouped];
    translator.sourceText = text;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:translator];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible = YES;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
#endif
