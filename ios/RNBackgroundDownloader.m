#import "RNBackgroundDownloader.h"
#import "RNBGDTaskConfig.h"
#import <MMKV/MMKV.h>
#ifdef RCT_NEW_ARCH_ENABLED
#import "<GeneratedSpec>.h"
#endif

#define ID_TO_CONFIG_MAP_KEY @"com.eko.bgdownloadidmap"
#define PROGRESS_INTERVAL_KEY @"progressInterval"

// DISABLES LOGS IN RELEASE MODE. NSLOG IS SLOW: https://stackoverflow.com/a/17738695/3452513
#ifdef DEBUG
#define DLog( s, ... ) NSLog( @"<%p %@:(%d)> %@", self, [[NSString stringWithUTF8String:__FILE__] lastPathComponent], __LINE__, [NSString stringWithFormat:(s), ##__VA_ARGS__] )
#else
#define DLog( s, ... )
#endif

static CompletionHandler storedCompletionHandler;

@implementation RNBackgroundDownloader {
    MMKV *mmkv;
    NSURLSession *urlSession;
    NSURLSessionConfiguration *sessionConfig;
    NSNumber *sharedLock;
    NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *taskToConfigMap;
    NSMutableDictionary<NSString *, NSURLSessionTask *> *idToTaskMap;
    NSMutableDictionary<NSString *, NSData *> *idToResumeDataMap;
    NSMutableDictionary<NSString *, NSNumber *> *idToPercentMap;
    NSMutableDictionary<NSString *, NSDictionary *> *downloadProgressReports;
    NSMutableDictionary<NSString *, NSDictionary *> *uploadProgressReports;
    float progressInterval;
    NSDate *lastProgressReportedAt;
    BOOL isBridgeListenerInited;
    BOOL isJavascriptLoaded;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue
{
    return dispatch_queue_create("com.eko.backgrounddownloader", DISPATCH_QUEUE_SERIAL);
}

+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"downloadBegin",
        @"downloadProgress",
        @"downloadComplete",
        @"downloadFailed",
        @"uploadBegin",
        @"uploadProgress",
        @"uploadComplete",
        @"uploadFailed"
    ];
}

- (NSDictionary *)constantsToExport {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return @{
        @"documents": [paths firstObject],
        @"TaskRunning": @(NSURLSessionTaskStateRunning),
        @"TaskSuspended": @(NSURLSessionTaskStateSuspended),
        @"TaskCanceling": @(NSURLSessionTaskStateCanceling),
        @"TaskCompleted": @(NSURLSessionTaskStateCompleted)
    };
}

- (id)init {
    DLog(@"[RNBackgroundDownloader] - [init]");
    self = [super init];
    if (self) {
        [MMKV initializeMMKV:nil];
        mmkv = [MMKV mmkvWithID:@"RNBackgroundDownloader"];

        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        NSString *sessionIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
        sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:sessionIdentifier];
        sessionConfig.HTTPMaximumConnectionsPerHost = 4;
        sessionConfig.timeoutIntervalForRequest = 60 * 60; // MAX TIME TO GET NEW DATA IN REQUEST - 1 HOUR
        sessionConfig.timeoutIntervalForResource = 60 * 60 * 24; // MAX TIME TO DOWNLOAD RESOURCE - 1 DAY
        sessionConfig.discretionary = NO;
        sessionConfig.sessionSendsLaunchEvents = YES;
        if (@available(iOS 9.0, *)) {
            sessionConfig.shouldUseExtendedBackgroundIdleMode = YES;
        }
        if (@available(iOS 13.0, *)) {
            sessionConfig.allowsExpensiveNetworkAccess = YES;
        }

        sharedLock = [NSNumber numberWithInt:1];

        NSData *taskToConfigMapData = [mmkv getDataForKey:ID_TO_CONFIG_MAP_KEY];
        NSMutableDictionary *taskToConfigMapDataDefault = [[NSMutableDictionary alloc] init];
        NSMutableDictionary *taskToConfigMapDataDecoded = taskToConfigMapData != nil ? [self deserialize:taskToConfigMapData] : nil;
        taskToConfigMap = taskToConfigMapDataDecoded != nil ? taskToConfigMapDataDecoded : taskToConfigMapDataDefault;
        idToTaskMap = [[NSMutableDictionary alloc] init];
        idToResumeDataMap = [[NSMutableDictionary alloc] init];
        idToPercentMap = [[NSMutableDictionary alloc] init];

        downloadProgressReports = [[NSMutableDictionary alloc] init];
        uploadProgressReports = [[NSMutableDictionary alloc] init];
        float progressIntervalScope = [mmkv getFloatForKey:PROGRESS_INTERVAL_KEY];
        progressInterval = isnan(progressIntervalScope) ? 1.0 : progressIntervalScope;
        lastProgressReportedAt = [[NSDate alloc] init];

        [self registerBridgeListener];
    }

    return self;
}

- (void)dealloc {
    DLog(@"[RNBackgroundDownloader] - [dealloc]");
    [self unregisterSession];
    [self unregisterBridgeListener];
}

- (void)handleBridgeHotReload:(NSNotification *) note {
    DLog(@"[RNBackgroundDownloader] - [handleBridgeHotReload]");
    [self unregisterSession];
    [self unregisterBridgeListener];
}

- (void)lazyRegisterSession {
    DLog(@"[RNBackgroundDownloader] - [lazyRegisterSession]");
    @synchronized (sharedLock) {
        if (urlSession == nil) {
            urlSession = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:nil];
        }
    }
}

- (void)unregisterSession {
    DLog(@"[RNBackgroundDownloader] - [unregisterSession]");
    if (urlSession) {
        [urlSession invalidateAndCancel];
        urlSession = nil;
    }
}

- (void)registerBridgeListener {
    DLog(@"[RNBackgroundDownloader] - [registerBridgeListener]");
    @synchronized (sharedLock) {
        if (isBridgeListenerInited != YES) {
            isBridgeListenerInited = YES;
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleBridgeAppEnterForeground:)
                                                  name:UIApplicationWillEnterForegroundNotification
                                                  object:nil];

            [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleBridgeHotReload:)
                                                  name:RCTJavaScriptWillStartLoadingNotification
                                                  object:nil];

            [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleBridgeJavascriptLoad:)
                                                  name:RCTJavaScriptDidLoadNotification
                                                  object:nil];
        }
    }
}

- (void)unregisterBridgeListener {
    DLog(@"[RNBackgroundDownloader] - [unregisterBridgeListener]");
    if (isBridgeListenerInited == YES) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        isBridgeListenerInited = NO;
    }
}

- (void)handleBridgeJavascriptLoad:(NSNotification *) note {
    DLog(@"[RNBackgroundDownloader] - [handleBridgeJavascriptLoad]");
    isJavascriptLoaded = YES;
}

- (void)handleBridgeAppEnterForeground:(NSNotification *) note {
    DLog(@"[RNBackgroundDownloader] - [handleBridgeAppEnterForeground]");
    [self resumeTasks];
}

- (void)resumeTasks {
    @synchronized (sharedLock) {
        DLog(@"[RNBackgroundDownloader] - [resumeTasks]");
        [urlSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
            for (NSURLSessionDownloadTask *task in downloadTasks) {
                // running - 0
                // suspended - 1
                // canceling - 2
                // completed - 3
                if (task.state == NSURLSessionTaskStateRunning) {
                    [task suspend];
                    [task resume];
                }
            }
        }];
    }
}

- (void)removeTaskFromMap: (NSURLSessionTask *)task {
    DLog(@"[RNBackgroundDownloader] - [removeTaskFromMap]");
    @synchronized (sharedLock) {
        NSNumber *taskId = @(task.taskIdentifier);
        RNBGDTaskConfig *taskConfig = taskToConfigMap[taskId];

        [taskToConfigMap removeObjectForKey:taskId];
        [mmkv setData:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

        if (taskConfig) {
            [self -> idToTaskMap removeObjectForKey:taskConfig.id];
            [idToPercentMap removeObjectForKey:taskConfig.id];
        }
    }
}

#pragma mark - JS exported methods

RCT_EXPORT_METHOD(upload: (NSDictionary *)options) {
    DLog(@"[RNBackgroundDownloader] - [upload]");

    NSString *identifier = options[@"id"];
    NSString *urlString = options[@"url"];
    NSString *source = options[@"source"];
    NSString *httpMethod = options[@"method"] ?: @"POST";
    NSString *metadata = options[@"metadata"];
    NSDictionary *headers = options[@"headers"];

    if (!identifier || !urlString || !source) {
        DLog(@"[RNBackgroundDownloader] - [Error] id, url, and source must be set for upload");
        return;
    }

    NSURL *uploadURL = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:uploadURL];
    request.HTTPMethod = httpMethod;

    for (NSString *key in headers) {
        [request setValue:headers[key] forHTTPHeaderField:key];
    }

    NSURL *fileURL = [NSURL fileURLWithPath:source];

    RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary:@{
        @"id": identifier,
        @"type": @(RNBGDTaskConfigTypeUpload),
        @"url": urlString,
        @"source": source,
        @"httpMethod": httpMethod,
        @"metadata": metadata ?: @"{}",
        @"headers": headers ?: @{}
    }];

    @synchronized (sharedLock) {
        [self lazyRegisterSession];

        NSURLSessionUploadTask *uploadTask = [urlSession uploadTaskWithRequest:request fromFile:fileURL];
        if (!uploadTask) {
            DLog(@"[RNBackgroundDownloader] - [Error] failed to create upload task");
            return;
        }

        taskToConfigMap[@(uploadTask.taskIdentifier)] = taskConfig;
        [mmkv setData:[self serialize:taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];
        idToTaskMap[identifier] = uploadTask;

        [uploadTask resume];
    }
}


RCT_EXPORT_METHOD(download: (NSDictionary *) options) {
    DLog(@"[RNBackgroundDownloader] - [download]");
    NSString *identifier = options[@"id"];
    NSString *url = options[@"url"];
    NSString *destination = options[@"destination"];
    NSString *metadata = options[@"metadata"];
    NSDictionary *headers = options[@"headers"];

    NSNumber *progressIntervalScope = options[@"progressInterval"];
    if (progressIntervalScope) {
        progressInterval = [progressIntervalScope intValue] / 1000;
        [mmkv setFloat:progressInterval forKey:PROGRESS_INTERVAL_KEY];
    }

    NSString *destinationRelative = [self getRelativeFilePathFromPath:destination];

    DLog(@"[RNBackgroundDownloader] - [download] url %@ destination %@ progressInterval %f", url, destination, progressInterval);
    if (identifier == nil || url == nil || destination == nil) {
        DLog(@"[RNBackgroundDownloader] - [Error] id, url and destination must be set");
        return;
    }

    if (destinationRelative == nil) {
        DLog(@"[RNBackgroundDownloader] - [Error] destination is not valid");
        return;
    }

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url]];
    // Query in the checkForExistingDownloads function.
    [request setValue:identifier forHTTPHeaderField:@"configId"];
    if (headers != nil) {
        for (NSString *headerKey in headers) {
            [request setValue:[headers valueForKey:headerKey] forHTTPHeaderField:headerKey];
        }
    }

    @synchronized (sharedLock) {
        [self lazyRegisterSession];

        NSURLSessionDownloadTask __strong *task = [urlSession downloadTaskWithRequest:request];
        if (task == nil) {
            DLog(@"[RNBackgroundDownloader] - [Error] failed to create download task");
            return;
        }

        RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary: @{
            @"id": identifier,
            @"type": @(RNBGDTaskConfigTypeDownload),
            @"url": url,
            @"destination": destination,
            @"metadata": metadata
        }];

        taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
        [mmkv setData:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

        self->idToTaskMap[identifier] = task;
        idToPercentMap[identifier] = @0.0;

        [task resume];
        lastProgressReportedAt = [[NSDate alloc] init];
    }
}

RCT_EXPORT_METHOD(pauseTask: (NSString *)identifier) {
    DLog(@"[RNBackgroundDownloader] - [pauseTask]");
    @synchronized (sharedLock) {
        NSURLSessionTask *task = self->idToTaskMap[identifier];
        if (task != nil && task.state == NSURLSessionTaskStateRunning) {
            [task suspend];
        }
    }
}

RCT_EXPORT_METHOD(resumeTask: (NSString *)identifier) {
    DLog(@"[RNBackgroundDownloader] - [resumeTask]");
    @synchronized (sharedLock) {
        NSURLSessionTask *task = self->idToTaskMap[identifier];
        if (task != nil && task.state == NSURLSessionTaskStateSuspended) {
            [task resume];
        }
    }
}

RCT_EXPORT_METHOD(stopTask: (NSString *)identifier) {
    DLog(@"[RNBackgroundDownloader] - [stopTask]");
    @synchronized (sharedLock) {
        NSURLSessionTask *task = self->idToTaskMap[identifier];
        if (task != nil) {
            [task cancel];
            [self removeTaskFromMap:task];
        }
    }
}

RCT_EXPORT_METHOD(completeHandler:(nonnull NSString *)jobId resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    DLog(@"[RNBackgroundDownloader] - [completeHandlerIOS]");
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (storedCompletionHandler) {
            storedCompletionHandler();
            storedCompletionHandler = nil;
        }
    }];

    resolve(nil);
}

RCT_EXPORT_METHOD(checkForExistingDownloads: (RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    DLog(@"[RNBackgroundDownloader] - [checkForExistingDownloads]");
    [self lazyRegisterSession];
    [urlSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        NSMutableArray *foundTasks = [[NSMutableArray alloc] init];
        @synchronized (self->sharedLock) {
            // Wait for the Thread to be ready.
            // Prevents the first task from failing.
            [NSThread sleepForTimeInterval:0.1f];

            for (NSURLSessionDownloadTask *foundTask in downloadTasks) {
                NSURLSessionDownloadTask __strong *task = foundTask;

                // The task.taskIdentifier may change after the Application is closed and opened.
                // We cannot rely on this value to launch tasks.
                // The download function adds an configId value to the headers.
                // We query taskToConfigMap with this value.
                NSDictionary *headers = task.currentRequest.allHTTPHeaderFields;
                NSString *configId = headers[@"configId"];

                NSNumber *taskIdentifier = @-1;
                RNBGDTaskConfig *taskConfig = nil;
                for (NSNumber *key in self->taskToConfigMap) {
                    RNBGDTaskConfig *config = self->taskToConfigMap[key];
                    if ([config.id isEqualToString:configId]) {
                        taskIdentifier = key;
                        taskConfig = config;
                        break;
                    }
                }

                if (taskConfig && [taskIdentifier intValue] != -1) {
                    BOOL taskCompletedOrSuspended = (task.state == NSURLSessionTaskStateCompleted || task.state == NSURLSessionTaskStateSuspended);
                    BOOL taskNeedBytes = task.countOfBytesReceived < task.countOfBytesExpectedToReceive;
                    if (taskCompletedOrSuspended && taskNeedBytes) {
                        NSData *taskResumeData = task.error.userInfo[NSURLSessionDownloadTaskResumeData];

                        // The code -999 is used because the task was abandoned for some reason.
                        if (task.error && task.error.code == -999 && taskResumeData != nil) {
                            task = [self->urlSession downloadTaskWithResumeData:taskResumeData];
                        } else {
                            task = [self->urlSession downloadTaskWithURL:task.currentRequest.URL];
                        }
                        [task resume];
                    }

                    NSNumber *percent = task.countOfBytesExpectedToReceive > 0
                        ? [NSNumber numberWithFloat:(float)task.countOfBytesReceived/(float)task.countOfBytesExpectedToReceive]
                        : @0.0;

                    [foundTasks addObject:@{
                        @"id": taskConfig.id,
                        @"type": @(taskConfig.type),
                        @"metadata": taskConfig.metadata,
                        @"state": [NSNumber numberWithInt:(int)task.state],
                        @"bytes": [NSNumber numberWithLongLong:task.countOfBytesReceived],
                        @"bytesTotal": [NSNumber numberWithLongLong:task.countOfBytesExpectedToReceive]
                    }];
                    taskConfig.reportedBegin = YES;
                    self->taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
                    self->idToTaskMap[taskConfig.id] = task;
                    self->idToPercentMap[taskConfig.id] = percent;
                } else {
                    [task cancel];
                }
            }
            
            for (NSURLSessionUploadTask *foundTask in uploadTasks) {
                NSURLSessionUploadTask __strong *task = foundTask;

                // The task.taskIdentifier may change after the Application is closed and opened.
                // We cannot rely on this value to launch tasks.
                // The download function adds an configId value to the headers.
                // We query taskToConfigMap with this value.
                NSDictionary *headers = task.currentRequest.allHTTPHeaderFields;
                NSString *configId = headers[@"configId"];

                NSNumber *taskIdentifier = @-1;
                RNBGDTaskConfig *taskConfig = nil;
                for (NSNumber *key in self->taskToConfigMap) {
                    RNBGDTaskConfig *config = self->taskToConfigMap[key];
                    if ([config.id isEqualToString:configId]) {
                        taskIdentifier = key;
                        taskConfig = config;
                        break;
                    }
                }

                if (taskConfig && [taskIdentifier intValue] != -1) {
                    BOOL taskCompletedOrSuspended = (task.state == NSURLSessionTaskStateCompleted || task.state == NSURLSessionTaskStateSuspended);
                    BOOL taskNeedBytes = task.countOfBytesSent < task.countOfBytesExpectedToSend;
                    if (taskCompletedOrSuspended && taskNeedBytes) {
                        NSData *taskResumeData = task.error.userInfo[NSURLSessionDownloadTaskResumeData];

                        // The code -999 is used because the task was abandoned for some reason.
                        if (task.error && task.error.code == -999 && taskResumeData != nil) {
                            if (@available(iOS 17.0, *)) {
                                task = [self->urlSession uploadTaskWithResumeData:taskResumeData];
                            }
                        }
                        [task resume];
                    }

                    NSNumber *percent = task.countOfBytesExpectedToSend > 0
                        ? [NSNumber numberWithFloat:(float)task.countOfBytesSent/(float)task.countOfBytesExpectedToSend]
                        : @0.0;

                    [foundTasks addObject:@{
                        @"id": taskConfig.id,
                        @"type": @(taskConfig.type),
                        @"metadata": taskConfig.metadata,
                        @"state": [NSNumber numberWithInt:(int)task.state],
                        @"bytes": [NSNumber numberWithLongLong:task.countOfBytesSent],
                        @"bytesTotal": [NSNumber numberWithLongLong:task.countOfBytesExpectedToSend]
                    }];
                    taskConfig.reportedBegin = YES;
                    self->taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
                    self->idToTaskMap[taskConfig.id] = task;
                    self->idToPercentMap[taskConfig.id] = percent;
                } else {
                    [task cancel];
                }
            }

            resolve(foundTasks);
        }
    }];
}

#pragma mark - NSURLSessionDownloadDelegate methods
- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location {
    DLog(@"[RNBackgroundDownloader] - [didFinishDownloadingToURL]");
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskConfig = taskToConfigMap[@(downloadTask.taskIdentifier)];

        if (taskConfig != nil) {
            NSError *error = [self getServerError:downloadTask];
            if (error == nil) {
                [self saveFile:taskConfig downloadURL:location error:&error];
            }

            if (self.bridge && isJavascriptLoaded) {
                if (error == nil) {
                    NSDictionary *responseHeaders = ((NSHTTPURLResponse *)downloadTask.response).allHeaderFields;
                    [self sendEventWithName:@"downloadComplete" body:@{
                        @"id": taskConfig.id,
                        @"headers": responseHeaders,
                        @"location": taskConfig.destination,
                        @"bytes": [NSNumber numberWithLongLong:downloadTask.countOfBytesReceived],
                        @"bytesTotal": [NSNumber numberWithLongLong:downloadTask.countOfBytesExpectedToReceive]
                    }];
                } else {
                    [self sendEventWithName:@"downloadFailed" body:@{
                        @"id": taskConfig.id,
                        @"error": [error localizedDescription],
                        // TODO
                        @"errorCode": @-1
                    }];
                }
            }

            [self removeTaskFromMap:downloadTask];
        }
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedbytesTotal:(int64_t)expectedbytesTotal {
    DLog(@"[RNBackgroundDownloader] - [didResumeAtOffset]");
}

- (void)URLSession:(NSURLSession *)session
    downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didWriteData:(int64_t)bytesDownloaded
    totalBytesWritten:(int64_t)bytesTotalWritten
    totalBytesExpectedToWrite:(int64_t)bytesTotalExpectedToWrite
{
    DLog(@"[RNBackgroundDownloader] - [didWriteData]");
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskConfig = taskToConfigMap[@(downloadTask.taskIdentifier)];
        if (taskConfig != nil) {
            if (!taskConfig.reportedBegin) {
                NSDictionary *responseHeaders = ((NSHTTPURLResponse *)downloadTask.response).allHeaderFields;
                if (self.bridge && isJavascriptLoaded) {
                    [self sendEventWithName:@"downloadBegin" body:@{
                        @"id": taskConfig.id,
                        @"expectedBytes": [NSNumber numberWithLongLong: bytesTotalExpectedToWrite],
                        @"headers": responseHeaders
                    }];
                }
                taskConfig.reportedBegin = YES;
            }

            NSNumber *prevPercent = idToPercentMap[taskConfig.id];
            NSNumber *percent = [NSNumber numberWithFloat:(float)bytesTotalWritten/(float)bytesTotalExpectedToWrite];
            if ([percent floatValue] - [prevPercent floatValue] > 0.01f) {
                downloadProgressReports[taskConfig.id] = @{
                    @"id": taskConfig.id,
                    @"bytes": [NSNumber numberWithLongLong: bytesTotalWritten],
                    @"bytesTotal": [NSNumber numberWithLongLong: bytesTotalExpectedToWrite]
                };
                idToPercentMap[taskConfig.id] = percent;
            }

            NSDate *now = [[NSDate alloc] init];
            if ([now timeIntervalSinceDate:lastProgressReportedAt] > progressInterval && downloadProgressReports.count > 0) {
                if (self.bridge && isJavascriptLoaded) {
                    [self sendEventWithName:@"downloadProgress" body:[downloadProgressReports allValues]];
                }
                lastProgressReportedAt = now;
                [downloadProgressReports removeAllObjects];
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session
 task:(NSURLSessionTask *)task
 didSendBodyData:(int64_t)bytesSent
 totalBytesSent:(int64_t)totalBytesSent
 totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    DLog(@"[RNBackgroundDownloader] - [didSendData]");
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskConfig = taskToConfigMap[@(task.taskIdentifier)];
        if (!taskConfig || !isJavascriptLoaded || !self.bridge) return;
        
        if (!taskConfig.reportedBegin) {
            if (self.bridge && isJavascriptLoaded) {
                [self sendEventWithName:@"uploadBegin" body:@{
                    @"id": taskConfig.id,
                    @"expectedBytes": [NSNumber numberWithLongLong: totalBytesExpectedToSend],
                    @"headers": @[]
                }];
            }
            taskConfig.reportedBegin = YES;
        }
        
        NSNumber *prevPercent = idToPercentMap[taskConfig.id];
        NSNumber *percent = [NSNumber numberWithFloat:(float)totalBytesSent / (float)totalBytesExpectedToSend];
        
        if ([percent floatValue] - [prevPercent floatValue] > 0.01f) {
            uploadProgressReports[taskConfig.id] = @{
                @"id": taskConfig.id,
                @"bytes": [NSNumber numberWithLongLong: totalBytesSent],
                @"bytesTotal": [NSNumber numberWithLongLong: totalBytesExpectedToSend]
            };
            idToPercentMap[taskConfig.id] = percent;
        }
        NSDate *now = [[NSDate alloc] init];
        if ([now timeIntervalSinceDate:lastProgressReportedAt] > progressInterval && uploadProgressReports.count > 0) {
            [self sendEventWithName:@"uploadProgress" body:[uploadProgressReports allValues]];
            lastProgressReportedAt = now;
            [uploadProgressReports removeAllObjects];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    DLog(@"[RNBackgroundDownloader] - [didCompleteWithError]");
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskConfig = taskToConfigMap[@(task.taskIdentifier)];
        if (taskConfig == nil) {
            return;
        }
        
        // Upload task has no dedicated method to finish upload
        if (taskConfig.source != nil) {
            DLog(@"[RNBackgroundDownloader] - [didFinishUploadingToURL]");
            if (self.bridge && isJavascriptLoaded) {
                if (error == nil) {
                    [self sendEventWithName:@"uploadComplete" body:@{
                        @"id": taskConfig.id,
                        @"headers": @[],
                        @"location": taskConfig.source,
                        @"bytes": [NSNumber numberWithLongLong:task.countOfBytesSent],
                        @"bytesTotal": [NSNumber numberWithLongLong:task.countOfBytesExpectedToSend]
                    }];
                } else {
                    [self sendEventWithName:@"uploadFailed" body:@{
                        @"id": taskConfig.id,
                        @"error": [error localizedDescription],
                        // TODO
                        @"errorCode": @-1
                    }];
                }
            }

            [self removeTaskFromMap:task];
            return;
        }

        // -999 code represents incomplete tasks.
        // Required to continue resume tasks.
        if (error != nil && error.code != -999) {
            if (self.bridge && isJavascriptLoaded) {
                NSString * eventName = @"downloadFailed";
                [self sendEventWithName:eventName body:@{
                    @"id": taskConfig.id,
                    @"error": [error localizedDescription],
                    // TODO
                    @"errorCode": @-1
                }];
            }
            [self removeTaskFromMap:task];
        }
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    DLog(@"[RNBackgroundDownloader] - [URLSessionDidFinishEventsForBackgroundURLSession]");
}

+ (void)setCompletionHandlerWithIdentifier: (NSString *)identifier completionHandler: (CompletionHandler)completionHandler {
    DLog(@"[RNBackgroundDownloader] - [setCompletionHandlerWithIdentifier]");
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    NSString *sessionIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
    if ([sessionIdentifier isEqualToString:identifier]) {
        storedCompletionHandler = completionHandler;
    }
}

- (NSError *)getServerError: (nonnull NSURLSessionDownloadTask *)downloadTask {
    DLog(@"[RNBackgroundDownloader] - [getServerError]");
    NSError *serverError;
    NSInteger httpStatusCode = [((NSHTTPURLResponse *)downloadTask.response) statusCode];

    // 200 and 206 codes are successful http codes.
    // 200 code is received in tasks downloaded with downloadTaskWithURL.
    // 206 code is received in tasks downloaded with downloadTaskWithResumeData.
    if(httpStatusCode != 200 && httpStatusCode != 206) {
        serverError = [NSError errorWithDomain:NSURLErrorDomain
                                          code:httpStatusCode
                                      userInfo:@{NSLocalizedDescriptionKey: [NSHTTPURLResponse localizedStringForStatusCode: httpStatusCode]}];
    }

    return serverError;
}

- (BOOL)saveFile: (nonnull RNBGDTaskConfig *) taskConfig downloadURL:(nonnull NSURL *)location error:(NSError **)saveError {
    DLog(@"[RNBackgroundDownloader] - [saveFile]");
    // taskConfig.destination is absolute path.
    // The absolute path may change when the application is restarted.
    // But the relative path remains the same.
    // Relative paths are used to recreate the Absolute path.
    NSString *rootPath = [self getRootPathFromPath:taskConfig.destination];
    NSString *fileRelativePath = [self getRelativeFilePathFromPath:taskConfig.destination];
    NSString *fileAbsolutePath = [rootPath stringByAppendingPathComponent:fileRelativePath];
    NSURL *destinationURL = [NSURL fileURLWithPath:fileAbsolutePath];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager createDirectoryAtURL:[destinationURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager removeItemAtURL:destinationURL error:nil];

    return [fileManager moveItemAtURL:location toURL:destinationURL error:saveError];
}

#pragma mark - serialization
- (NSData *)serialize:(NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *)taskMap {
    NSError *error = nil;
    NSData *taskMapRaw = [NSKeyedArchiver archivedDataWithRootObject:taskMap requiringSecureCoding:YES error:&error];

    if (error) {
        DLog(@"[RNBackgroundDownloader] Serialization error: %@", error);
        return nil;
    }

    return taskMapRaw;
}

- (NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *)deserialize:(NSData *)taskMapRaw {
    NSError *error = nil;
    // Creates a list of classes that can be stored.
    NSSet *classes = [NSSet setWithObjects:[RNBGDTaskConfig class], [NSMutableDictionary class], [NSNumber class], [NSString class], nil];
    NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *taskMap = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:taskMapRaw error:&error];

    if (error) {
        DLog(@"[RNBackgroundDownloader] Deserialization error: %@", error);
        return nil;
    }

    return taskMap;
}

- (NSString *)getRootPathFromPath:(NSString *)path {
    // [...]/data/Containers/Bundle/Application/[UUID]
    NSString *bundlePath = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    NSString *bundlePathWithoutUuid = [self getPathWithoutSuffixUuid:bundlePath];
    // [...]/data/Containers/Data/Application/[UUID]
    NSString *dataPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByDeletingLastPathComponent];
    NSString *dataPathWithoutUuid = [self getPathWithoutSuffixUuid:dataPath];

    if ([path hasPrefix:bundlePathWithoutUuid]) {
        return bundlePath;
    }

    if ([path hasPrefix:dataPathWithoutUuid]) {
        return dataPath;
    }

    return nil;
}

- (NSString *)getRelativeFilePathFromPath:(NSString *)path {
    // [...]/data/Containers/Bundle/Application/[UUID]
    NSString *bundlePath = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
    NSString *bundlePathWithoutUuid = [self getPathWithoutSuffixUuid:bundlePath];

    // [...]/data/Containers/Data/Application/[UUID]
    NSString *dataPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByDeletingLastPathComponent];
    NSString *dataPathWithoutUuid = [self getPathWithoutSuffixUuid:dataPath];

    if ([path hasPrefix:bundlePathWithoutUuid]) {
        return [path substringFromIndex:[bundlePath length]];
    }

    if ([path hasPrefix:dataPathWithoutUuid]) {
        return [path substringFromIndex:[dataPath length]];
    }

    return nil;
}

- (NSString *)getPathWithoutSuffixUuid:(NSString *)path {
    NSString *pattern = @"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];

    NSString *pathSuffix = [path lastPathComponent];
    NSTextCheckingResult *pathSuffixIsUuid = [regex firstMatchInString:pathSuffix options:0 range:NSMakeRange(0, [pathSuffix length])];
    if (pathSuffixIsUuid) {
        return [path stringByDeletingLastPathComponent];
    }

    return path;
}

@end

#ifdef RCT_NEW_ARCH_ENABLED
 - (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
 {
    return std::make_shared<facebook::react::<MyModuleSpecJSI>>(params);
 }
#endif
