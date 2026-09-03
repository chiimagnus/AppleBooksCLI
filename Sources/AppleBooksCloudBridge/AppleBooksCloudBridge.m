#import "AppleBooksCloudBridge.h"

#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <sys/stat.h>

static BOOL ABIsDirectory(NSString *path) {
    struct stat value;
    return lstat(path.fileSystemRepresentation, &value) == 0 && (value.st_mode & S_IFMT) == S_IFDIR;
}

static BOOL ABIsRegularFile(NSString *path) {
    struct stat value;
    return lstat(path.fileSystemRepresentation, &value) == 0 && (value.st_mode & S_IFMT) == S_IFREG;
}

static BOOL ABLayoutIsExact(NSString *root, NSString *database) {
    NSString *storeDirectory = [root stringByAppendingPathComponent:@"BCCloudCollections"];
    NSString *expected = [storeDirectory stringByAppendingPathComponent:@"BCCloudCollections"];
    return [[database stringByStandardizingPath] isEqualToString:[expected stringByStandardizingPath]]
        && ABIsDirectory(root)
        && ABIsDirectory(storeDirectory)
        && ABIsRegularFile(database);
}

static int ABCloudDetailCount(NSString *database, NSString *collectionID) {
    sqlite3 *connection = NULL;
    int opened = sqlite3_open_v2(database.fileSystemRepresentation, &connection, SQLITE_OPEN_READONLY, NULL);
    if (opened != SQLITE_OK || connection == NULL) {
        if (connection != NULL) sqlite3_close_v2(connection);
        return -1;
    }

    sqlite3_stmt *statement = NULL;
    int count = -1;
    if (sqlite3_prepare_v2(
            connection,
            "SELECT count(*) FROM ZBCCOLLECTIONDETAIL WHERE ZCOLLECTIONID=?",
            -1,
            &statement,
            NULL
        ) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, collectionID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_ROW) count = sqlite3_column_int(statement, 0);
    }
    if (statement != NULL) sqlite3_finalize(statement);
    sqlite3_close_v2(connection);
    return count;
}

static id ABAllocateWithObject(Class cls, NSString *initializer, id argument) {
    id object = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("alloc"));
    return ((id (*)(id, SEL, id))objc_msgSend)(object, NSSelectorFromString(initializer), argument);
}

static void ABSetObject(id object, NSString *selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, NSSelectorFromString(selector), value);
}

static void ABSetBool(id object, NSString *selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, NSSelectorFromString(selector), value);
}

static void ABSetInteger(id object, NSString *selector, long long value) {
    ((void (*)(id, SEL, long long))objc_msgSend)(object, NSSelectorFromString(selector), value);
}

int32_t ABProjectCollectionDetail(
    const char *root_path,
    const char *canonical_database_path,
    const char *collection_id,
    const char *title,
    int64_t sort_order,
    double modification_date_reference_seconds
) {
    @autoreleasepool {
        if (root_path == NULL || canonical_database_path == NULL || collection_id == NULL || title == NULL) return 1;

        NSString *root = [NSString stringWithUTF8String:root_path];
        NSString *database = [NSString stringWithUTF8String:canonical_database_path];
        NSString *collectionID = [NSString stringWithUTF8String:collection_id];
        NSString *collectionTitle = [NSString stringWithUTF8String:title];
        if (root == nil || database == nil || collectionID.length == 0 || collectionTitle.length == 0) return 1;
        if ([[NSUUID alloc] initWithUUIDString:collectionID] == nil || sort_order < 0 || !isfinite(modification_date_reference_seconds)) return 1;
        if (!ABLayoutIsExact(root, database)) return 2;

        int before = ABCloudDetailCount(database, collectionID);
        if (before < 0) return 3;
        if (before != 0) return 4;

        if (dlopen("/System/Library/PrivateFrameworks/BookDataStore.framework/BookDataStore", RTLD_NOW) == NULL) return 5;
        Class collectionsManagerClass = NSClassFromString(@"BCCloudCollectionsManager");
        Class dataSourceClass = NSClassFromString(@"BCCloudDataSource");
        Class dataManagerClass = NSClassFromString(@"BCCloudDataManager");
        Class detailClass = NSClassFromString(@"BCCollectionDetail");
        Class mutableDetailClass = NSClassFromString(@"BCMutableCollectionDetail");
        if (collectionsManagerClass == Nil || dataSourceClass == Nil || dataManagerClass == Nil || detailClass == Nil || mutableDetailClass == Nil) return 6;

        SEL dataSourceInitializer = NSSelectorFromString(@"initWithManagedObjectModel:rootDirectoryURL:legacyRootDirectoryURL:nameOnDisk:");
        SEL dataManagerInitializer = NSSelectorFromString(@"initWithCloudDataSource:entityName:notificationName:immutableClass:mutableClass:syncManager:cloudKitController:");
        SEL detailInitializer = NSSelectorFromString(@"initWithCollectionID:");
        SEL propertyIDKeySelector = NSSelectorFromString(@"propertyIDKey");
        SEL setCloudDataSelector = NSSelectorFromString(@"setCloudData:predicate:propertyIDKey:completion:");
        NSArray<NSString *> *detailSelectors = @[
            @"setName:", @"setHidden:", @"setSortMode:", @"setSortOrder:", @"setModificationDate:"
        ];
        if (![dataSourceClass instancesRespondToSelector:dataSourceInitializer]
            || ![dataManagerClass instancesRespondToSelector:dataManagerInitializer]
            || ![dataManagerClass instancesRespondToSelector:setCloudDataSelector]
            || ![mutableDetailClass instancesRespondToSelector:detailInitializer]
            || ![(id)detailClass respondsToSelector:propertyIDKeySelector]) return 16;
        for (NSString *selectorName in detailSelectors) {
            if (![mutableDetailClass instancesRespondToSelector:NSSelectorFromString(selectorName)]) return 16;
        }

        NSBundle *bundle = [NSBundle bundleForClass:collectionsManagerClass];
        NSURL *modelURL = [bundle URLForResource:@"BCCloudCollections" withExtension:@"momd"];
        NSManagedObjectModel *model = modelURL == nil ? nil : [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
        if (model == nil) return 7;

        id dataSource = ((id (*)(id, SEL))objc_msgSend)(dataSourceClass, sel_registerName("alloc"));
        dataSource = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            dataSource,
            dataSourceInitializer,
            model,
            [NSURL fileURLWithPath:root isDirectory:YES],
            nil,
            @"BCCloudCollections"
        );
        if (dataSource == nil) return 8;
        if (!ABLayoutIsExact(root, database)) return 9;
        if (ABCloudDetailCount(database, collectionID) != 0) return 4;

        id dataManager = ((id (*)(id, SEL))objc_msgSend)(dataManagerClass, sel_registerName("alloc"));
        dataManager = ((id (*)(id, SEL, id, id, id, Class, Class, id, id))objc_msgSend)(
            dataManager,
            dataManagerInitializer,
            dataSource,
            @"BCCollectionDetail",
            @"BCCloudCollectionDetailManagerChanged",
            detailClass,
            mutableDetailClass,
            nil,
            nil
        );
        if (dataManager == nil) return 10;

        id detail = ABAllocateWithObject(mutableDetailClass, @"initWithCollectionID:", collectionID);
        if (detail == nil) return 11;
        ABSetObject(detail, @"setName:", collectionTitle);
        ABSetBool(detail, @"setHidden:", NO);
        ABSetInteger(detail, @"setSortMode:", 6);
        ABSetInteger(detail, @"setSortOrder:", sort_order);
        ABSetObject(
            detail,
            @"setModificationDate:",
            [NSDate dateWithTimeIntervalSinceReferenceDate:modification_date_reference_seconds]
        );

        NSDictionary *data = @{ collectionID: detail };
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"collectionID == %@", collectionID];
        NSString *propertyIDKey = ((id (*)(id, SEL))objc_msgSend)(detailClass, propertyIDKeySelector);
        if (propertyIDKey.length == 0) return 12;

        __block BOOL completed = NO;
        void (^completion)(void) = ^{ completed = YES; };
        ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(
            dataManager,
            setCloudDataSelector,
            data,
            predicate,
            propertyIDKey,
            completion
        );

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!completed && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!completed) return 13;
        if (!ABLayoutIsExact(root, database)) return 14;
        return ABCloudDetailCount(database, collectionID) == 1 ? 0 : 15;
    }
}
