#import "SponsorPreferences.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import <CommonCrypto/CommonDigest.h>

NSArray<NSDictionary<NSString *, NSString *> *> *YTKACESponsorCategoryDefinitions(void) {
    return @[
        @{@"id": @"sponsor", @"title": YTKACELocalized(@"Sponsor"), @"color": @"#00D400",
          @"description": YTKACELocalized(@"Paid promotion, paid referral links, and direct ads")},
        @{@"id": @"selfpromo", @"title": YTKACELocalized(@"Self Promotion"), @"color": @"#FFFF00",
          @"description": YTKACELocalized(@"Unpaid self-promotion, merch, social links, or personal projects")},
        @{@"id": @"interaction", @"title": YTKACELocalized(@"Interaction Reminder"), @"color": @"#CC00FF",
          @"description": YTKACELocalized(@"Reminders to subscribe, like, hit the bell, or follow")},
        @{@"id": @"intro", @"title": YTKACELocalized(@"Intermission / Intro"), @"color": @"#00FFFF",
          @"description": YTKACELocalized(@"Intro animations, title sequences, interval screens, or logos")},
        @{@"id": @"outro", @"title": YTKACELocalized(@"Endcards / Credits"), @"color": @"#0202ED",
          @"description": YTKACELocalized(@"Credits, endcards, and final greetings at video end")},
        @{@"id": @"preview", @"title": YTKACELocalized(@"Preview / Recap"), @"color": @"#008FD6",
          @"description": YTKACELocalized(@"Previews of upcoming content or recaps of previous videos")},
        @{@"id": @"music_offtopic", @"title": YTKACELocalized(@"Non-Music Section"), @"color": @"#FF9900",
          @"description": YTKACELocalized(@"Dialogue or non-music portions in official music videos")},
        @{@"id": @"filler", @"title": YTKACELocalized(@"Filler"), @"color": @"#7300FF",
          @"description": YTKACELocalized(@"Tangents, jokes, or scenes that add no substance to the video")},
        @{@"id": @"poi_highlight", @"title": YTKACELocalized(@"Highlight"), @"color": @"#FF1684",
          @"description": YTKACELocalized(@"The most interesting moment or point of interest in the video")}
    ];
}

NSString *YTKACESponsorBehaviorKey(NSString *category) {
    return [@"YTKACE.Preference.SponsorBlock.Behavior."
        stringByAppendingString:category ?: @""];
}

NSString *YTKACESponsorColorKey(NSString *category) {
    return [@"YTKACE.Preference.SponsorBlock.Color."
        stringByAppendingString:category ?: @""];
}

static NSDictionary<NSString *, NSString *> *YTKACESponsorDefinition(NSString *category) {
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition;
    }
    return nil;
}

NSString *YTKACESponsorCategoryTitle(NSString *category) {
    NSDictionary *definition = YTKACESponsorDefinition(category);
    if (definition != nil && [definition[@"title"] isKindOfClass:NSString.class]) {
        return definition[@"title"];
    }
    return YTKACELocalized(@"Sponsor");
}

NSInteger YTKACESponsorCategoryBehavior(NSString *category) {
    id stored = YTKACEPreferenceObject(YTKACESponsorBehaviorKey(category));
    if ([stored respondsToSelector:@selector(integerValue)]) {
        return MAX(0, MIN([stored integerValue], 3));
    }
    if ([category isEqualToString:@"sponsor"]) {
        id legacy = YTKACEPreferenceObject(@"YTKACE.Preference.SponsorBlock.Mode");
        return [legacy respondsToSelector:@selector(integerValue)] &&
            [legacy integerValue] == 1 ? 1 : 0;
    }
    return 2;
}

NSArray<NSString *> *YTKACESponsorEnabledCategories(void) {
    NSMutableArray *categories = [NSMutableArray array];
    for (NSDictionary *definition in YTKACESponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        if (YTKACESponsorCategoryBehavior(category) != 2) {
            [categories addObject:category];
        }
    }
    return categories;
}

static UIColor *YTKACEColorFromHex(NSString *hex) {
    NSString *value = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#"
                                                              withString:@""] uppercaseString];
    if (value.length != 6) return UIColor.systemGreenColor;
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

UIColor *YTKACESponsorCategoryColor(NSString *category) {
    NSDictionary *definition = YTKACESponsorDefinition(category);
    NSString *stored = YTKACEPreferenceObject(YTKACESponsorColorKey(category));
    NSString *hex = [stored isKindOfClass:NSString.class] && stored.length != 0
        ? stored : definition[@"color"];
    return YTKACEColorFromHex(hex);
}

NSInteger YTKACESponsorNotificationMode(void) {
    id stored = YTKACEPreferenceObject(@"YTKACE.Preference.SponsorBlock.NotificationMode");
    return [stored respondsToSelector:@selector(integerValue)]
        ? MAX(0, MIN([stored integerValue], 2)) : 0;
}

static NSTimeInterval YTKACESponsorDuration(NSString *key) {
    id stored = YTKACEPreferenceObject(key);
    double value = [stored respondsToSelector:@selector(doubleValue)]
        ? [stored doubleValue] : 4.0;
    return MAX(1.0, MIN(value, 10.0));
}

NSTimeInterval YTKACESponsorSkipAlertDuration(void) {
    return YTKACESponsorDuration(@"YTKACE.Preference.SponsorBlock.SkipAlertSeconds");
}

NSTimeInterval YTKACESponsorUnskipAlertDuration(void) {
    return YTKACESponsorDuration(@"YTKACE.Preference.SponsorBlock.UnskipAlertSeconds");
}

NSString *YTKACESponsorCategoryDescription(NSString *category) {
    for (NSDictionary *def in YTKACESponsorCategoryDefinitions()) {
        if ([def[@"id"] isEqualToString:category]) {
            return def[@"description"] ?: @"";
        }
    }
    return @"";
}

NSString * const YTKACESponsorUserIDKey = @"YTKACE.Preference.SponsorBlock.UserID";
NSString * const YTKACESponsorSubmitButtonKey = @"YTKACE.Preference.SponsorBlock.SubmitButton";
NSString * const YTKACESponsorTimeSavedKey = @"YTKACE.Preference.SponsorBlock.TimeSaved";
NSString * const YTKACESponsorSkipCountKey = @"YTKACE.Preference.SponsorBlock.SkipCount";
NSString * const YTKACESponsorChannelWhitelistKey = @"YTKACE.Preference.SponsorBlock.ChannelWhitelist";
NSString * const YTKACESponsorOthersTimeSavedKey = @"YTKACE.Preference.SponsorBlock.OthersTimeSaved";
NSString * const YTKACESponsorOthersSkipsCountKey = @"YTKACE.Preference.SponsorBlock.OthersSkipsCount";
NSString * const YTKACESponsorSubmissionsCountKey = @"YTKACE.Preference.SponsorBlock.SubmissionsCount";
NSString * const YTKACESponsorShowTimeWithSkipsKey = @"YTKACE.Preference.SponsorBlock.ShowTimeWithSkips";
NSString * const YTKACESponsorFullVideoLabelsKey = @"YTKACE.Preference.SponsorBlock.FullVideoLabels";
NSString * const YTKACESponsorUserNameKey = @"YTKACE.Preference.SponsorBlock.UserName";

BOOL YTKACESponsorShowTimeWithSkipsEnabled(void) {
    return YTKACEFeatureEnabled(YTKACESponsorShowTimeWithSkipsKey);
}

BOOL YTKACESponsorFullVideoLabelsEnabled(void) {
    if (!YTKACESponsorBlockEnabled()) return NO;
    id val = YTKACEPreferenceObject(YTKACESponsorFullVideoLabelsKey);
    if (val == nil) return YES;
    if ([val respondsToSelector:@selector(boolValue)]) {
        return [val boolValue];
    }
    return YES;
}

struct YTKACESponsorCalcInterval {
    double start;
    double end;
};

double YTKACESponsorCalculateSkippedDuration(NSArray<NSDictionary *> *segments, double duration) {
    if (segments == nil || segments.count == 0 || !isfinite(duration) || duration <= 0.0) {
        return 0.0;
    }
    NSMutableArray<NSValue *> *intervalValues = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        if (![seg isKindOfClass:NSDictionary.class]) continue;
        NSString *category = [seg[@"category"] isKindOfClass:NSString.class]
            ? seg[@"category"] : @"sponsor";
        NSString *actionType = [seg[@"actionType"] isKindOfClass:NSString.class]
            ? seg[@"actionType"] : @"skip";
        if ([category isEqualToString:@"poi_highlight"] ||
            [actionType isEqualToString:@"poi"] ||
            [actionType isEqualToString:@"full"] ||
            [actionType isEqualToString:@"mute"]) {
            continue;
        }
        if (YTKACESponsorCategoryBehavior(category) != 0) {
            continue;
        }
        double start = 0.0;
        double end = 0.0;
        if ([seg[@"start"] respondsToSelector:@selector(doubleValue)]) {
            start = [seg[@"start"] doubleValue];
            end = [seg[@"end"] doubleValue];
        } else if ([seg[@"segment"] isKindOfClass:NSArray.class] && [seg[@"segment"] count] >= 2) {
            start = [seg[@"segment"][0] doubleValue];
            end = [seg[@"segment"][1] doubleValue];
        }
        start = MAX(0.0, MIN(start, duration));
        end = MAX(0.0, MIN(end, duration));
        if (end > start) {
            struct YTKACESponsorCalcInterval iv = { start, end };
            [intervalValues addObject:[NSValue valueWithBytes:&iv objCType:@encode(struct YTKACESponsorCalcInterval)]];
        }
    }
    if (intervalValues.count == 0) {
        return 0.0;
    }
    [intervalValues sortUsingComparator:^NSComparisonResult(NSValue *val1, NSValue *val2) {
        struct YTKACESponsorCalcInterval iv1, iv2;
        [val1 getValue:&iv1];
        [val2 getValue:&iv2];
        if (iv1.start < iv2.start) return NSOrderedAscending;
        if (iv1.start > iv2.start) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    double totalSkipped = 0.0;
    struct YTKACESponsorCalcInterval current;
    [intervalValues[0] getValue:&current];

    for (NSUInteger i = 1; i < intervalValues.count; i++) {
        struct YTKACESponsorCalcInterval next;
        [intervalValues[i] getValue:&next];
        if (next.start <= current.end) {
            if (next.end > current.end) {
                current.end = next.end;
            }
        } else {
            totalSkipped += (current.end - current.start);
            current = next;
        }
    }
    totalSkipped += (current.end - current.start);

    return MIN(totalSkipped, duration);
}

NSString *YTKACESponsorUserID(void) {
    id stored = YTKACEPreferenceObject(YTKACESponsorUserIDKey);
    if ([stored isKindOfClass:NSString.class] && [stored length] >= 8) {
        return stored;
    }
    NSString *generated = [[NSUUID UUID] UUIDString];
    YTKACESetPreferenceObject(YTKACESponsorUserIDKey, generated);
    return generated;
}

void YTKACESetSponsorUserID(NSString *userID) {
    NSString *clean = [userID stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
    if (clean.length == 0) {
        clean = [userID stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSString *current = YTKACEPreferenceObject(YTKACESponsorUserIDKey);
    if (clean.length > 0) {
        if (current != nil && ![clean isEqualToString:current]) {
            // User ID changed: reset cached community stats so old stats don't bleed into new ID
            YTKACESetPreferenceObject(YTKACESponsorOthersTimeSavedKey, @(0.0));
            YTKACESetPreferenceObject(YTKACESponsorOthersSkipsCountKey, @(0));
            YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(0));
            YTKACESetPreferenceObject(YTKACESponsorUserNameKey, nil);
        }
        YTKACESetPreferenceObject(YTKACESponsorUserIDKey, clean);
        YTKACESponsorFetchUserInfo(nil);
    } else {
        YTKACESetPreferenceObject(YTKACESponsorUserIDKey, nil);
        YTKACESetPreferenceObject(YTKACESponsorOthersTimeSavedKey, @(0.0));
        YTKACESetPreferenceObject(YTKACESponsorOthersSkipsCountKey, @(0));
        YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(0));
        YTKACESetPreferenceObject(YTKACESponsorUserNameKey, nil);
    }
}

NSString *YTKACEResetSponsorUserID(void) {
    NSString *generated = [[NSUUID UUID] UUIDString];
    YTKACESetPreferenceObject(YTKACESponsorUserIDKey, generated);
    // Reset all community stats to zero for the fresh anonymous user ID
    YTKACESetPreferenceObject(YTKACESponsorOthersTimeSavedKey, @(0.0));
    YTKACESetPreferenceObject(YTKACESponsorOthersSkipsCountKey, @(0));
    YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(0));
    YTKACESetPreferenceObject(YTKACESponsorUserNameKey, nil);
    YTKACESponsorFetchUserInfo(nil);
    return generated;
}

NSString *YTKACESponsorComputePublicUserID(NSString *userID) {
    if (userID.length == 0) return nil;
    NSString *clean = [userID stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
    if (clean.length == 0) return nil;

    // 1. If already 64 hex characters [0-9a-fA-F]{64}, it is already a publicUserID
    if (clean.length == 64) {
        NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
        if ([[clean stringByTrimmingCharactersInSet:hexSet] length] == 0) {
            return [clean lowercaseString];
        }
    }

    // 2. Run SHA-256 5000 times (matching official SponsorBlock specification)
    NSData *inputData = [clean dataUsingEncoding:NSUTF8StringEncoding];
    if (inputData.length == 0) return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(inputData.bytes, (CC_LONG)inputData.length, digest);

    char hexBuffer[CC_SHA256_DIGEST_LENGTH * 2];
    static const char hexDigits[] = "0123456789abcdef";
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        hexBuffer[i * 2]     = hexDigits[(digest[i] >> 4) & 0x0F];
        hexBuffer[i * 2 + 1] = hexDigits[digest[i] & 0x0F];
    }

    for (int round = 1; round < 5000; round++) {
        CC_SHA256(hexBuffer, CC_SHA256_DIGEST_LENGTH * 2, digest);
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            hexBuffer[i * 2]     = hexDigits[(digest[i] >> 4) & 0x0F];
            hexBuffer[i * 2 + 1] = hexDigits[digest[i] & 0x0F];
        }
    }

    return [[NSString alloc] initWithBytes:hexBuffer
                                    length:CC_SHA256_DIGEST_LENGTH * 2
                                  encoding:NSASCIIStringEncoding];
}

NSString *YTKACESponsorPublicUserID(void) {
    NSString *userID = YTKACESponsorUserID();
    return YTKACESponsorComputePublicUserID(userID);
}

BOOL YTKACESponsorSubmitButtonEnabled(void) {
    id stored = YTKACEPreferenceObject(YTKACESponsorSubmitButtonKey);
    return stored == nil ? YES : [stored boolValue];
}

NSString *YTKACEExtractUserIDFromInput(NSString *rawInput) {
    if (rawInput.length == 0) return nil;
    NSString *trimmed = [rawInput stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"\uFEFF"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    trimmed = [trimmed stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;

    // 1. JSON check: parse SponsorBlock PC extension exported JSON first
    NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    if (data != nil) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            id uid = json[@"userID"] ?: json[@"userId"] ?: json[@"uuid"];
            if ([uid isKindOfClass:NSString.class]) {
                NSString *clean = [(NSString *)uid stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
                if (clean.length >= 8) {
                    return clean;
                }
            }
        }
    }

    // 2. XML / Plist string check: e.g. <key>userID</key><string>...</string> from iSponsorBlock.plist
    NSRegularExpression *plistRegex = [NSRegularExpression
        regularExpressionWithPattern:@"<key>userID</key>\\s*<string>([^<]+)</string>"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *plistMatch = [plistRegex firstMatchInString:trimmed
                                                             options:0
                                                               range:NSMakeRange(0, trimmed.length)];
    if (plistMatch != nil && plistMatch.numberOfRanges > 1) {
        NSString *found = [trimmed substringWithRange:[plistMatch rangeAtIndex:1]];
        NSString *extracted = [found stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
        if (extracted.length >= 8) return extracted;
    }

    // 3. Key-value string check: e.g. userID: "..." or userID = "..."
    NSRegularExpression *kvRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:userID|userId|publicUserID)\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-\\.~ ]+)[\"']?"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *kvMatch = [kvRegex firstMatchInString:trimmed
                                                        options:0
                                                          range:NSMakeRange(0, trimmed.length)];
    if (kvMatch != nil && kvMatch.numberOfRanges > 1) {
        NSString *found = [trimmed substringWithRange:[kvMatch rangeAtIndex:1]];
        NSString *extracted = [found stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
        if (extracted.length >= 8) return extracted;
    }

    // 4. Direct UUID pattern: 8-4-4-4-12 hex string (exact case preserved!)
    NSRegularExpression *uuidRegex = [NSRegularExpression
        regularExpressionWithPattern:@"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        options:0 error:nil];
    NSTextCheckingResult *uuidMatch = [uuidRegex firstMatchInString:trimmed
                                                            options:0
                                                              range:NSMakeRange(0, trimmed.length)];
    if (uuidMatch != nil && uuidMatch.range.location != NSNotFound) {
        return [trimmed substringWithRange:uuidMatch.range];
    }

    // 5. Fallback: single token between 8 and 80 characters (newlines stripped)
    NSString *cleanToken = [rawInput stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
    if (cleanToken.length >= 8 && cleanToken.length <= 80) {
        return cleanToken;
    }

    return nil;
}

BOOL YTKACESponsorImportConfig(NSString *rawInput, NSString **outSummary) {
    if (rawInput.length == 0) return NO;
    NSString *trimmed = [rawInput stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"\uFEFF"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    trimmed = [trimmed stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;

    NSMutableArray<NSString *> *importedItems = [NSMutableArray array];

    // Try parsing as JSON first
    NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    if (data != nil) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = (NSDictionary *)json;

            // 1. User ID (exact string preserved from JSON, newlines trimmed)
            id uid = dict[@"userID"] ?: dict[@"userId"] ?: dict[@"uuid"];
            if ([uid isKindOfClass:NSString.class]) {
                NSString *cleanUID = [(NSString *)uid stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
                if (cleanUID.length >= 8) {
                    YTKACESetSponsorUserID(cleanUID);
                    [importedItems addObject:YTKACELocalized(@"User ID")];
                }
            }

            // 2. Whitelisted Channels
            id whitelist = dict[@"whitelistedChannels"] ?: dict[@"whitelist"];
            if ([whitelist isKindOfClass:NSArray.class]) {
                NSUInteger count = 0;
                for (id ch in (NSArray *)whitelist) {
                    if ([ch isKindOfClass:NSString.class] && [ch length] > 0) {
                        YTKACESponsorSetChannelWhitelisted(ch, YES);
                        count++;
                    }
                }
                if (count > 0) {
                    [importedItems addObject:[NSString stringWithFormat:@"%lu %@",
                                             (unsigned long)count, YTKACELocalized(@"channels")]];
                }
            }

            // 3. Category Colors: parse BOTH categoryPillColors AND barTypes
            NSUInteger colorsCount = 0;
            id colors = dict[@"categoryPillColors"] ?: dict[@"colors"];
            if ([colors isKindOfClass:NSDictionary.class]) {
                for (NSString *cat in (NSDictionary *)colors) {
                    id col = colors[cat];
                    if ([col isKindOfClass:NSString.class] && [col length] > 0) {
                        YTKACESetPreferenceObject(YTKACESponsorColorKey(cat), col);
                        colorsCount++;
                    }
                }
            }
            id barTypes = dict[@"barTypes"];
            if ([barTypes isKindOfClass:NSDictionary.class]) {
                for (NSString *cat in (NSDictionary *)barTypes) {
                    if ([cat hasPrefix:@"preview-"]) continue;
                    id info = barTypes[cat];
                    NSString *hex = nil;
                    if ([info isKindOfClass:NSDictionary.class] && info[@"color"]) {
                        hex = info[@"color"];
                    } else if ([info isKindOfClass:NSString.class]) {
                        hex = info;
                    }
                    if ([hex isKindOfClass:NSString.class] && hex.length > 0) {
                        YTKACESetPreferenceObject(YTKACESponsorColorKey(cat), hex);
                        colorsCount++;
                    }
                }
            }
            if (colorsCount > 0) {
                [importedItems addObject:YTKACELocalized(@"Category Colors")];
            }

            // 4. Category Selections / Behaviors
            id selections = dict[@"categorySelections"];
            if ([selections isKindOfClass:NSArray.class] && [selections count] > 0) {
                NSUInteger behaviorsConfigured = 0;
                for (id item in (NSArray *)selections) {
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    NSString *catName = item[@"name"];
                    id optVal = item[@"option"];
                    if ([catName isKindOfClass:NSString.class] && optVal != nil && [optVal respondsToSelector:@selector(integerValue)]) {
                        NSInteger opt = [optVal integerValue];
                        // SponsorBlock PC:
                        // 0 = Disabled -> YTKACE: 2
                        // 1 = Manual Skip / Button -> YTKACE: 1 (or 3 for highlight)
                        // 2 = Auto-skip -> YTKACE: 0 (or 3 for highlight)
                        // 3 = Show Marker / Seekbar -> YTKACE: 3
                        NSInteger mapped = 2;
                        if ([catName isEqualToString:@"poi_highlight"]) {
                            mapped = (opt == 0) ? 2 : 3;
                        } else {
                            if (opt == 2) {
                                mapped = 0; // Auto-skip
                            } else if (opt == 1) {
                                mapped = 1; // Ask / Manual
                            } else if (opt == 3) {
                                mapped = 3; // Show Marker
                            } else {
                                mapped = 2; // Disabled
                            }
                        }
                        YTKACESetPreferenceObject(YTKACESponsorBehaviorKey(catName), @(mapped));
                        behaviorsConfigured++;
                    }
                }
                if (behaviorsConfigured > 0) {
                    [importedItems addObject:YTKACELocalized(@"Category Behaviors")];
                }
            }

            // 5. Minutes Saved & Skip Count
            id minSaved = dict[@"minutesSaved"];
            if ([minSaved respondsToSelector:@selector(doubleValue)]) {
                double sec = [minSaved doubleValue] * 60.0;
                if (sec > 0) {
                    YTKACESetPreferenceObject(YTKACESponsorTimeSavedKey, @(sec));
                    [importedItems addObject:YTKACELocalized(@"Time Saved")];
                }
            }
            id skipCount = dict[@"skipCount"];
            if ([skipCount respondsToSelector:@selector(integerValue)]) {
                NSInteger count = [skipCount integerValue];
                if (count > 0) {
                    YTKACESetPreferenceObject(YTKACESponsorSkipCountKey, @(count));
                    [importedItems addObject:YTKACELocalized(@"Skips Count")];
                }
            }
            id contrib = dict[@"sponsorTimesContributed"] ?: dict[@"submissionCountSinceCategories"] ?: dict[@"segmentCount"];
            if ([contrib respondsToSelector:@selector(integerValue)]) {
                NSInteger count = [contrib integerValue];
                if (count > 0) {
                    NSInteger current = YTKACESponsorSubmissionsCount();
                    YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(MAX(current, count)));
                    [importedItems addObject:[NSString stringWithFormat:@"%ld %@",
                                             (long)count,
                                             YTKACELocalized(count == 1 ? @"submission" : @"submissions")]];
                }
            }

            // 5b. Community Time Saved & View Count if present in JSON/backup
            id othersMin = dict[@"othersMinutesSaved"] ?: dict[@"othersTimeSaved"] ?: dict[@"communityMinutesSaved"];
            if ([othersMin respondsToSelector:@selector(doubleValue)]) {
                double sec = [othersMin doubleValue] * 60.0;
                if (sec > 0) {
                    YTKACESetPreferenceObject(YTKACESponsorOthersTimeSavedKey, @(sec));
                }
            }
            id othersViews = dict[@"viewCount"] ?: dict[@"othersSkips"] ?: dict[@"othersSkipsCount"] ?: dict[@"savedPeopleFrom"];
            if ([othersViews respondsToSelector:@selector(integerValue)]) {
                NSInteger count = [othersViews integerValue];
                if (count > 0) {
                    YTKACESetPreferenceObject(YTKACESponsorOthersSkipsCountKey, @(count));
                }
            }

            // 6. Notice & Skipping preferences
            id skipNotice = dict[@"skipNoticeDuration"];
            if ([skipNotice respondsToSelector:@selector(doubleValue)]) {
                double val = [skipNotice doubleValue];
                if (val >= 1.0 && val <= 10.0) {
                    YTKACESetPreferenceObject(@"YTKACE.Preference.SponsorBlock.SkipAlertSeconds", @(val));
                }
            }
            id audioFeedback = dict[@"audioNotificationOnSkip"];
            if ([audioFeedback respondsToSelector:@selector(boolValue)]) {
                YTKACESetPreferenceObject(@"YTKACE.Preference.SponsorBlock.AudioFeedback", @([audioFeedback boolValue]));
            }
            id disableSkipping = dict[@"disableSkipping"];
            if ([disableSkipping respondsToSelector:@selector(boolValue)]) {
                BOOL enabled = ![disableSkipping boolValue];
                YTKACESetPreferenceObject(YTKACESponsorBlockKey, @(enabled));
            }
            id showTimeWithSkips = dict[@"showTimeWithSkips"];
            if ([showTimeWithSkips respondsToSelector:@selector(boolValue)]) {
                YTKACESetPreferenceObject(YTKACESponsorShowTimeWithSkipsKey, @([showTimeWithSkips boolValue]));
            }

            if (importedItems.count > 0) {
                YTKACESponsorFetchUserInfo(nil);
                if (outSummary) {
                    *outSummary = [NSString stringWithFormat:@"%@: %@",
                                   YTKACELocalized(@"Imported"),
                                   [importedItems componentsJoinedByString:@", "]];
                }
                return YES;
            }
        }
    }

    // Try parsing as iSponsorBlock plist
    NSRegularExpression *plistRegex = [NSRegularExpression
        regularExpressionWithPattern:@"<key>userID</key>\\s*<string>([^<]+)</string>"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *plistMatch = [plistRegex firstMatchInString:trimmed
                                                             options:0
                                                               range:NSMakeRange(0, trimmed.length)];
    if (plistMatch != nil && plistMatch.numberOfRanges > 1) {
        NSString *found = [trimmed substringWithRange:[plistMatch rangeAtIndex:1]];
        NSString *extracted = [found stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (extracted.length >= 8) {
            YTKACESetSponsorUserID(extracted);
            if (outSummary) {
                *outSummary = [NSString stringWithFormat:@"%@: %@",
                               YTKACELocalized(@"Imported"), YTKACELocalized(@"User ID")];
            }
            return YES;
        }
    }

    // Fallback: direct User ID or UUID
    NSString *extracted = YTKACEExtractUserIDFromInput(trimmed);
    if (extracted.length >= 8) {
        YTKACESetSponsorUserID(extracted);
        if (outSummary) {
            *outSummary = YTKACELocalized(@"User ID saved");
        }
        return YES;
    }

    return NO;
}

NSString *YTKACESponsorExportJSON(void) {
    NSString *userID = YTKACESponsorUserID();
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    NSMutableDictionary *barTypes = [NSMutableDictionary dictionary];
    NSMutableArray *categorySelections = [NSMutableArray array];
    for (NSDictionary *def in YTKACESponsorCategoryDefinitions()) {
        NSString *catID = def[@"id"];
        NSString *stored = YTKACEPreferenceObject(YTKACESponsorColorKey(catID));
        NSString *hex = (stored.length > 0) ? stored : def[@"color"];
        colors[catID] = hex;
        barTypes[catID] = @{@"color": hex, @"opacity": @"0.7"};

        NSInteger behavior = YTKACESponsorCategoryBehavior(catID);
        // YTKACE: 0 = Auto-skip, 1 = Ask, 2 = Disabled, 3 = Show in Seekbar
        // PC SponsorBlock: 2 = Auto-skip, 1 = Manual/Ask, 0 = Disabled, 3 = Show in Seekbar
        if (behavior != 2) {
            NSInteger pcOption = 2;
            if ([catID isEqualToString:@"poi_highlight"]) {
                pcOption = 1;
            } else if (behavior == 0) {
                pcOption = 2;
            } else if (behavior == 1) {
                pcOption = 1;
            } else if (behavior == 3) {
                pcOption = 3;
            }
            [categorySelections addObject:@{@"name": catID, @"option": @(pcOption)}];
        }
    }
    double totalSec = YTKACESponsorTotalTimeSaved();
    double minutesSaved = round((totalSec / 60.0) * 10.0) / 10.0;
    NSInteger skipCount = YTKACESponsorTotalSkipsCount();
    NSInteger submissionsCount = YTKACESponsorSubmissionsCount();
    double othersMinutesSaved = round((YTKACESponsorOthersTimeSaved() / 60.0) * 10.0) / 10.0;
    NSInteger othersSkipsCount = YTKACESponsorOthersSkipsCount();
    NSArray *whitelist = YTKACESponsorWhitelistedChannels();
    BOOL showTimeWithSkips = YTKACESponsorShowTimeWithSkipsEnabled();
    BOOL audioFeedback = YTKACEFeatureEnabled(@"YTKACE.Preference.SponsorBlock.AudioFeedback");
    BOOL disableSkipping = !YTKACEFeatureEnabled(YTKACESponsorBlockKey);
    double skipNoticeDuration = YTKACESponsorSkipAlertDuration();

    NSDictionary *exportDict = @{
        @"userID": userID,
        @"categoryPillColors": colors,
        @"barTypes": barTypes,
        @"categorySelections": categorySelections,
        @"whitelistedChannels": whitelist ?: @[],
        @"minutesSaved": @(minutesSaved),
        @"skipCount": @(skipCount),
        @"sponsorTimesContributed": @(submissionsCount),
        @"othersMinutesSaved": @(othersMinutesSaved),
        @"viewCount": @(othersSkipsCount),
        @"showTimeWithSkips": @(showTimeWithSkips),
        @"audioNotificationOnSkip": @(audioFeedback),
        @"disableSkipping": @(disableSkipping),
        @"skipNoticeDuration": @(skipNoticeDuration),
        @"exportedFrom": @"YTKACE",
        @"version": @"1.1.1"
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:exportDict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : userID;
}

double YTKACESponsorTotalTimeSaved(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorTimeSavedKey);
    return [val respondsToSelector:@selector(doubleValue)] ? [val doubleValue] : 0.0;
}

NSInteger YTKACESponsorTotalSkipsCount(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorSkipCountKey);
    return [val respondsToSelector:@selector(integerValue)] ? [val integerValue] : 0;
}

void YTKACESponsorAddSkippedTime(double seconds) {
    if (seconds <= 0.0) return;
    double current = YTKACESponsorTotalTimeSaved();
    NSInteger skips = YTKACESponsorTotalSkipsCount();
    YTKACESetPreferenceObject(YTKACESponsorTimeSavedKey, @(current + seconds));
    YTKACESetPreferenceObject(YTKACESponsorSkipCountKey, @(skips + 1));
}

void YTKACESponsorUndoSkippedTime(double seconds) {
    if (seconds < 0.0) seconds = 0.0;
    double current = YTKACESponsorTotalTimeSaved();
    NSInteger skips = YTKACESponsorTotalSkipsCount();
    YTKACESetPreferenceObject(YTKACESponsorTimeSavedKey, @(MAX(0.0, current - seconds)));
    YTKACESetPreferenceObject(YTKACESponsorSkipCountKey, @(MAX(0, skips - 1)));
}

NSString *YTKACESponsorFormattedTimeSaved(void) {
    double totalSec = YTKACESponsorTotalTimeSaved();
    if (totalSec < 1.0) {
        return [NSString stringWithFormat:@"0%@ (0 %@)",
                YTKACELocalized(@"s"), YTKACELocalized(@"skips")];
    }
    NSInteger totalMinutes = (NSInteger)round(totalSec / 60.0);
    NSInteger hours = totalMinutes / 60;
    NSInteger minutes = totalMinutes % 60;
    NSInteger skips = YTKACESponsorTotalSkipsCount();

    NSString *timeStr = hours > 0
        ? [NSString stringWithFormat:@"%ldh %02ldm", (long)hours, (long)minutes]
        : [NSString stringWithFormat:@"%ldm", (long)minutes];

    return [NSString stringWithFormat:@"%@ (%ld %@)",
            timeStr, (long)skips, YTKACELocalized(skips == 1 ? @"skip" : @"skips")];
}

double YTKACESponsorOthersTimeSaved(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorOthersTimeSavedKey);
    return [val respondsToSelector:@selector(doubleValue)] ? [val doubleValue] : 0.0;
}

NSInteger YTKACESponsorOthersSkipsCount(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorOthersSkipsCountKey);
    return [val respondsToSelector:@selector(integerValue)] ? [val integerValue] : 0;
}

NSInteger YTKACESponsorSubmissionsCount(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorSubmissionsCountKey);
    return [val respondsToSelector:@selector(integerValue)] ? [val integerValue] : 0;
}

NSString *YTKACESponsorUserName(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorUserNameKey);
    return [val isKindOfClass:NSString.class] ? val : nil;
}

void YTKACESponsorSetOthersStats(double minutesSaved, NSInteger skips, NSInteger submissions) {
    if (minutesSaved >= 0.0) {
        YTKACESetPreferenceObject(YTKACESponsorOthersTimeSavedKey, @(minutesSaved * 60.0));
    }
    if (skips >= 0) {
        YTKACESetPreferenceObject(YTKACESponsorOthersSkipsCountKey, @(skips));
    }
    if (submissions >= 0) {
        YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(submissions));
    }
}

static NSString *YTKACESponsorFormatHours(double minutes) {
    double rounded = round(minutes * 10.0) / 10.0;
    NSInteger totalMin = (NSInteger)floor(rounded);
    NSInteger years = totalMin / 525600;
    NSInteger days = (totalMin / 1440) % 365;
    NSInteger hours = (totalMin % 1440) / 60;
    double remMinutes = fmod(rounded, 60.0);

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (years > 0) [parts addObject:[NSString stringWithFormat:@"%ldy", (long)years]];
    if (days > 0) [parts addObject:[NSString stringWithFormat:@"%ldd", (long)days]];
    if (hours > 0) [parts addObject:[NSString stringWithFormat:@"%ldh", (long)hours]];
    [parts addObject:[NSString stringWithFormat:@"%.1f", remMinutes]];
    return [parts componentsJoinedByString:@" "];
}

NSString *YTKACESponsorFormattedOthersTimeSaved(void) {
    double totalSec = YTKACESponsorOthersTimeSaved();
    NSInteger skips = YTKACESponsorOthersSkipsCount();
    NSInteger subs = YTKACESponsorSubmissionsCount();
    if (totalSec < 1.0 && skips == 0) {
        if (subs > 0) {
            return [NSString stringWithFormat:@"0m (0 %@, %ld %@)",
                    YTKACELocalized(@"skips by others"),
                    (long)subs,
                    YTKACELocalized(subs == 1 ? @"submission" : @"submissions")];
        }
        return YTKACELocalized(@"0m (0 submissions)");
    }
    double minutes = totalSec / 60.0;
    NSString *timeStr = YTKACESponsorFormatHours(minutes);
    return [NSString stringWithFormat:@"%@ %ld %@ ( %@ %@ %@ )",
            YTKACELocalized(@"You have saved people from"),
            (long)skips,
            YTKACELocalized(skips == 1 ? @"segment" : @"segments"),
            timeStr,
            YTKACELocalized(fabs(minutes - 1.0) < 0.05 ? @"minute" : @"minutes"),
            YTKACELocalized(@"of their lives")];
}

void YTKACESponsorFetchUserInfo(void (^completion)(BOOL success, double othersTimeSaved, NSInteger othersSkips, NSInteger submissions)) {
    NSString *rawUserID = YTKACESponsorUserID();
    if (rawUserID.length == 0) {
        if (completion) completion(NO, 0, 0, 0);
        return;
    }

    NSString *cleanUserID = [rawUserID stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
    if (cleanUserID.length == 0) {
        if (completion) completion(NO, 0, 0, 0);
        return;
    }

    void (^fetchURL)(NSURL *url, void (^done)(BOOL ok, double seconds, NSInteger viewCount, NSInteger segmentCount, NSString *userName)) =
        ^(NSURL *url, void (^done)(BOOL ok, double seconds, NSInteger viewCount, NSInteger segmentCount, NSString *userName)) {
        static NSURLSession *session = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            config.timeoutIntervalForRequest = 10.0;
            config.timeoutIntervalForResource = 15.0;
            session = [NSURLSession sessionWithConfiguration:config];
        });

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"GET";
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:@"YTKACE/1.1.1 (iOS)" forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *task = [session dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
            if (error == nil && http.statusCode == 200 && data.length > 0 && data.length < 1024 * 1024) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:NSDictionary.class]) {
                    NSDictionary *dict = (NSDictionary *)json;
                    double minutes = 0.0;
                    if ([dict[@"minutesSaved"] respondsToSelector:@selector(doubleValue)]) {
                        minutes = [dict[@"minutesSaved"] doubleValue];
                    } else if ([dict[@"timeSaved"] respondsToSelector:@selector(doubleValue)]) {
                        minutes = [dict[@"timeSaved"] doubleValue];
                    } else if ([dict[@"overallStats"] isKindOfClass:NSDictionary.class] &&
                               [dict[@"overallStats"][@"minutesSaved"] respondsToSelector:@selector(doubleValue)]) {
                        minutes = [dict[@"overallStats"][@"minutesSaved"] doubleValue];
                    }

                    NSInteger viewCount = 0;
                    if ([dict[@"viewCount"] respondsToSelector:@selector(integerValue)]) {
                        viewCount = [dict[@"viewCount"] integerValue];
                    } else if ([dict[@"views"] respondsToSelector:@selector(integerValue)]) {
                        viewCount = [dict[@"views"] integerValue];
                    }

                    NSInteger segmentCount = 0;
                    if ([dict[@"segmentCount"] respondsToSelector:@selector(integerValue)]) {
                        segmentCount = [dict[@"segmentCount"] integerValue];
                    } else if ([dict[@"overallStats"] isKindOfClass:NSDictionary.class] &&
                               [dict[@"overallStats"][@"segmentCount"] respondsToSelector:@selector(integerValue)]) {
                        segmentCount = [dict[@"overallStats"][@"segmentCount"] integerValue];
                    }

                    NSString *userName = [dict[@"userName"] isKindOfClass:NSString.class]
                        ? dict[@"userName"] : nil;
                    done(YES, minutes * 60.0, viewCount, segmentCount, userName);
                    return;
                }
            }
            done(NO, 0, 0, 0, nil);
        }];
        [task resume];
    };

    void (^applyAndComplete)(BOOL success, double seconds, NSInteger viewCount, NSInteger segmentCount, NSString *userName) =
        ^(BOOL success, double seconds, NSInteger viewCount, NSInteger segmentCount, NSString *userName) {
        if (success) {
            YTKACESetPreferenceObject(YTKACESponsorOthersTimeSavedKey, @(seconds));
            YTKACESetPreferenceObject(YTKACESponsorOthersSkipsCountKey, @(viewCount));
            YTKACESetPreferenceObject(YTKACESponsorSubmissionsCountKey, @(segmentCount));
            if (userName.length > 0) {
                YTKACESetPreferenceObject(YTKACESponsorUserNameKey, userName);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, seconds, viewCount, segmentCount);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, YTKACESponsorOthersTimeSaved(), YTKACESponsorOthersSkipsCount(), YTKACESponsorSubmissionsCount());
            });
        }
    };

    // Build candidate list to query:
    // Candidate 1: cleanUserID as-is
    // Candidate 2: if cleanUserID has trailing space, try without; if it does not, try with trailing space
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObject:cleanUserID];
    if ([cleanUserID hasSuffix:@" "]) {
        NSString *trimmed = [cleanUserID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length >= 8) [candidates addObject:trimmed];
    } else {
        [candidates addObject:[cleanUserID stringByAppendingString:@" "]];
    }

    __block BOOL anyNetworkSuccess = NO;
    __block void (^testCandidateAtIndex)(NSUInteger idx);
    void (^testCandidateAtIndexBlock)(NSUInteger idx) = ^(NSUInteger idx) {
        if (idx >= candidates.count) {
            if (anyNetworkSuccess) {
                applyAndComplete(YES, 0.0, 0, 0, nil);
            } else {
                applyAndComplete(NO, 0.0, 0, 0, nil);
            }
            return;
        }

        NSString *cand = candidates[idx];
        NSString *pubID = YTKACESponsorComputePublicUserID(cand);
        if (pubID.length == 0) {
            testCandidateAtIndex(idx + 1);
            return;
        }

        static NSString * const kValuesQuery = @"&values=%5B%22userName%22%2C%22viewCount%22%2C%22minutesSaved%22%2C%22vip%22%2C%22permissions%22%2C%22segmentCount%22%5D";
        NSString *primaryUrlString = [NSString stringWithFormat:@"https://sponsor.ajay.app/api/userInfo?publicUserID=%@%@", pubID, kValuesQuery];
        NSURL *primaryURL = [NSURL URLWithString:primaryUrlString];

        fetchURL(primaryURL, ^(BOOL ok, double seconds, NSInteger viewCount, NSInteger segmentCount, NSString *userName) {
            if (ok) {
                anyNetworkSuccess = YES;
                if (segmentCount > 0 || seconds > 0 || viewCount > 0) {
                    if (![cand isEqualToString:cleanUserID]) {
                        YTKACESetPreferenceObject(YTKACESponsorUserIDKey, cand);
                    }
                    applyAndComplete(YES, seconds, viewCount, segmentCount, userName);
                    return;
                }
            }

            // Fallback: try ?userID= with cand
            if (cand.length != 64) {
                NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
                [allowed removeCharactersInString:@"+&=?# "];
                NSString *escapedID = [cand stringByAddingPercentEncodingWithAllowedCharacters:allowed];
                NSString *fbUrlString = [NSString stringWithFormat:@"https://sponsor.ajay.app/api/userInfo?userID=%@%@", escapedID ?: cand, kValuesQuery];
                NSURL *fbURL = [NSURL URLWithString:fbUrlString];
                if (fbURL != nil) {
                    fetchURL(fbURL, ^(BOOL fbOk, double fbSeconds, NSInteger fbViews, NSInteger fbSubs, NSString *fbUser) {
                        if (fbOk) {
                            anyNetworkSuccess = YES;
                            if (fbSubs > 0 || fbSeconds > 0 || fbViews > 0) {
                                if (![cand isEqualToString:cleanUserID]) {
                                    YTKACESetPreferenceObject(YTKACESponsorUserIDKey, cand);
                                }
                                applyAndComplete(YES, fbSeconds, fbViews, fbSubs, fbUser);
                                return;
                            }
                        }
                        testCandidateAtIndex(idx + 1);
                    });
                    return;
                }
            }

            testCandidateAtIndex(idx + 1);
        });
    };
    testCandidateAtIndex = testCandidateAtIndexBlock;
    testCandidateAtIndex(0);
}

NSArray<NSString *> *YTKACESponsorWhitelistedChannels(void) {
    id val = YTKACEPreferenceObject(YTKACESponsorChannelWhitelistKey);
    if ([val isKindOfClass:NSArray.class]) {
        return (NSArray<NSString *> *)val;
    }
    return @[];
}

BOOL YTKACESponsorIsChannelWhitelisted(NSString *channel) {
    if (channel.length == 0) return NO;
    NSString *trimmed = [channel stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    for (NSString *whitelisted in YTKACESponsorWhitelistedChannels()) {
        if ([whitelisted.lowercaseString isEqualToString:trimmed]) {
            return YES;
        }
    }
    return NO;
}

void YTKACESponsorSetChannelWhitelisted(NSString *channel, BOOL whitelisted) {
    if (channel.length == 0) return;
    NSString *trimmed = [channel stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *list = [YTKACESponsorWhitelistedChannels() mutableCopy];
    NSUInteger foundIndex = NSNotFound;
    for (NSUInteger i = 0; i < list.count; i++) {
        if ([list[i].lowercaseString isEqualToString:trimmed.lowercaseString]) {
            foundIndex = i;
            break;
        }
    }
    if (whitelisted && foundIndex == NSNotFound) {
        [list addObject:trimmed];
    } else if (!whitelisted && foundIndex != NSNotFound) {
        [list removeObjectAtIndex:foundIndex];
    }
    YTKACESetPreferenceObject(YTKACESponsorChannelWhitelistKey, [list copy]);
}

void YTKACESponsorClearWhitelistedChannels(void) {
    YTKACESetPreferenceObject(YTKACESponsorChannelWhitelistKey, @[]);
}

