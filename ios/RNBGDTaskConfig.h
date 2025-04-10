#import <Foundation/Foundation.h>

typedef enum : NSUInteger {
    RNBGDTaskConfigTypeDownload,
    RNBGDTaskConfigTypeUpload,
} RNBGDTaskConfigType;

@interface RNBGDTaskConfig : NSObject <NSCoding, NSSecureCoding>

@property NSString *_Nonnull id;
@property RNBGDTaskConfigType type;
@property NSString *_Nonnull url;
@property NSString *_Nonnull destination;
@property NSString *_Nonnull metadata;
@property NSString *_Nullable source;
@property NSString *_Nullable httpMethod;
@property NSDictionary *_Nullable headers;
@property BOOL reportedBegin;

- (id _Nullable)initWithDictionary:(NSDictionary *_Nonnull)dict;

@end

@implementation RNBGDTaskConfig

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (id _Nullable)initWithDictionary:(NSDictionary *_Nonnull)dict
{
    self = [super init];
    if (self)
    {
        self.id = dict[@"id"];
        self.type = [dict[@"type"] integerValue];
        self.url = dict[@"url"];
        self.destination = dict[@"destination"];
        self.metadata = dict[@"metadata"];
        self.source = dict[@"source"];
        self.httpMethod = dict[@"httpMethod"];
        self.headers = dict[@"headers"];
        self.reportedBegin = NO;
    }

    return self;
}

- (void)encodeWithCoder:(nonnull NSCoder *)aCoder
{
    [aCoder encodeObject:self.id forKey:@"id"];
    [aCoder encodeInt:self.type forKey:@"type"];
    [aCoder encodeObject:self.url forKey:@"url"];
    [aCoder encodeObject:self.destination forKey:@"destination"];
    [aCoder encodeObject:self.metadata forKey:@"metadata"];
    [aCoder encodeObject:self.source forKey:@"source"];
    [aCoder encodeObject:self.httpMethod forKey:@"httpMethod"];
    [aCoder encodeObject:self.headers forKey:@"headers"];
    [aCoder encodeBool:self.reportedBegin forKey:@"reportedBegin"];
}

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)aDecoder
{
    self = [super init];
    if (self)
    {
        self.id = [aDecoder decodeObjectForKey:@"id"];
        self.type = [aDecoder decodeIntForKey:@"type"];
        self.url = [aDecoder decodeObjectForKey:@"url"];
        self.destination = [aDecoder decodeObjectForKey:@"destination"];
        self.source = [aDecoder decodeObjectForKey:@"source"];
        self.httpMethod = [aDecoder decodeObjectForKey:@"httpMethod"];
        self.headers = [aDecoder decodeObjectForKey:@"headers"];
        NSString *metadata = [aDecoder decodeObjectForKey:@"metadata"];
        self.metadata = metadata != nil ? metadata : @"{}";
        self.reportedBegin = [aDecoder decodeBoolForKey:@"reportedBegin"];
    }

    return self;
}

@end
