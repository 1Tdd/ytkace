#pragma once
#import <Foundation/Foundation.h>
#include "../../Runtime/MediaPolicy.h"

static inline bool YTKACEReadSponsorInterval(id value, YTKACEMedia::Interval &range) {
    if (![value isKindOfClass:NSDictionary.class]) return false;
    id start = value[@"start"], end = value[@"end"];
    if (start == nil && [value[@"segment"] isKindOfClass:NSArray.class] && [value[@"segment"] count] == 2) {
        start = value[@"segment"][0]; end = value[@"segment"][1];
    }
    if (![start isKindOfClass:NSNumber.class] || ![end isKindOfClass:NSNumber.class]) return false;
    range = {[start doubleValue], [end doubleValue]};
    return YTKACEMedia::valid(range);
}

static inline std::vector<YTKACEMedia::Interval> YTKACESponsorCutTimeline(NSArray *segments) {
    std::vector<YTKACEMedia::Interval> ranges;
    for (id segment in segments) {
        YTKACEMedia::Interval range;
        if (YTKACEReadSponsorInterval(segment, range)) ranges.push_back(range);
    }
    return YTKACEMedia::normalize(ranges);
}
