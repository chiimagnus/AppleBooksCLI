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

static BOOL ABLayoutIsExact(NSString *root, NSString *database, NSString *storeName) {
    NSString *storeDirectory = [root stringByAppendingPathComponent:storeName];
    NSString *expected = [storeDirectory stringByAppendingPathComponent:storeName];
    return [[database stringByStandardizingPath] isEqualToString:[expected stringByStandardizingPath]]
        && ABIsDirectory(root)
        && ABIsDirectory(storeDirectory)
        && ABIsRegularFile(database);
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

static void ABSetDouble(id object, NSString *selector, double value) {
    ((void (*)(id, SEL, double))objc_msgSend)(object, NSSelectorFromString(selector), value);
}

static void ABSetFloat(id object, NSString *selector, float value) {
    ((void (*)(id, SEL, float))objc_msgSend)(object, NSSelectorFromString(selector), value);
}

static BOOL ABWaitForCompletion(BOOL *completed) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!*completed && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return *completed;
}

static int ABExactRowCount(NSString *database, NSString *table, NSString *column, NSString *value) {
    sqlite3 *connection = NULL;
    int opened = sqlite3_open_v2(database.fileSystemRepresentation, &connection, SQLITE_OPEN_READONLY, NULL);
    if (opened != SQLITE_OK || connection == NULL) {
        if (connection != NULL) sqlite3_close_v2(connection);
        return -1;
    }
    NSString *sql = [NSString stringWithFormat:@"SELECT count(*) FROM %@ WHERE %@=? COLLATE BINARY", table, column];
    sqlite3_stmt *statement = NULL;
    int count = -1;
    if (sqlite3_prepare_v2(connection, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, value.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_ROW) count = sqlite3_column_int(statement, 0);
    }
    if (statement != NULL) sqlite3_finalize(statement);
    sqlite3_close_v2(connection);
    return count;
}

static id ABCreateDataSource(NSString *root, NSString *modelName, NSString *storeName, Class ownerClass) {
    Class dataSourceClass = NSClassFromString(@"BCCloudDataSource");
    SEL initializer = NSSelectorFromString(@"initWithManagedObjectModel:rootDirectoryURL:legacyRootDirectoryURL:nameOnDisk:");
    if (dataSourceClass == Nil || ![dataSourceClass instancesRespondToSelector:initializer]) return nil;
    NSBundle *bundle = [NSBundle bundleForClass:ownerClass];
    NSURL *modelURL = [bundle URLForResource:modelName withExtension:@"momd"];
    NSManagedObjectModel *model = modelURL == nil ? nil : [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    if (model == nil) return nil;
    id dataSource = ((id (*)(id, SEL))objc_msgSend)(dataSourceClass, sel_registerName("alloc"));
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        dataSource,
        initializer,
        model,
        [NSURL fileURLWithPath:root isDirectory:YES],
        nil,
        storeName
    );
}

static id ABCreateDataManager(
    id dataSource,
    NSString *entityName,
    NSString *notificationName,
    Class immutableClass,
    Class mutableClass
) {
    Class dataManagerClass = NSClassFromString(@"BCCloudDataManager");
    SEL initializer = NSSelectorFromString(@"initWithCloudDataSource:entityName:notificationName:immutableClass:mutableClass:syncManager:cloudKitController:");
    if (dataManagerClass == Nil || ![dataManagerClass instancesRespondToSelector:initializer]) return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(dataManagerClass, sel_registerName("alloc"));
    return ((id (*)(id, SEL, id, id, id, Class, Class, id, id))objc_msgSend)(
        manager,
        initializer,
        dataSource,
        entityName,
        notificationName,
        immutableClass,
        mutableClass,
        nil,
        nil
    );
}

static BOOL ABSetCloudData(id manager, Class immutableClass, NSString *identity, NSString *identityKey, id object, NSPredicate *predicate) {
    SEL propertyIDKeySelector = NSSelectorFromString(@"propertyIDKey");
    SEL setCloudDataSelector = NSSelectorFromString(@"setCloudData:predicate:propertyIDKey:completion:");
    if (![manager respondsToSelector:setCloudDataSelector] || ![(id)immutableClass respondsToSelector:propertyIDKeySelector]) return NO;
    NSString *propertyIDKey = ((id (*)(id, SEL))objc_msgSend)(immutableClass, propertyIDKeySelector);
    if (propertyIDKey.length == 0 || ![propertyIDKey isEqualToString:identityKey]) return NO;
    __block BOOL completed = NO;
    void (^completion)(void) = ^{ completed = YES; };
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(
        manager,
        setCloudDataSelector,
        @{ identity: object },
        predicate,
        propertyIDKey,
        completion
    );
    return ABWaitForCompletion(&completed);
}

static BOOL ABDeleteCloudData(id manager, NSPredicate *predicate) {
    SEL selector = NSSelectorFromString(@"deleteCloudDataForPredicate:completion:");
    if (![manager respondsToSelector:selector]) return NO;
    __block BOOL completed = NO;
    void (^completion)(void) = ^{ completed = YES; };
    ((void (*)(id, SEL, id, id))objc_msgSend)(manager, selector, predicate, completion);
    return ABWaitForCompletion(&completed);
}

static NSString *ABText(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) return nil;
    if (sqlite3_column_type(statement, column) != SQLITE_TEXT) return nil;
    const unsigned char *text = sqlite3_column_text(statement, column);
    return text == NULL ? nil : [NSString stringWithUTF8String:(const char *)text];
}

static NSData *ABBlob(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) return nil;
    if (sqlite3_column_type(statement, column) != SQLITE_BLOB) return nil;
    int length = sqlite3_column_bytes(statement, column);
    const void *bytes = sqlite3_column_blob(statement, column);
    return length <= 0 || bytes == NULL ? [NSData data] : [NSData dataWithBytes:bytes length:(NSUInteger)length];
}

static NSDictionary *ABReadCollection(NSString *libraryDatabase, NSString *collectionID) {
    sqlite3 *connection = NULL;
    if (sqlite3_open_v2(libraryDatabase.fileSystemRepresentation, &connection, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || connection == NULL) {
        if (connection != NULL) sqlite3_close_v2(connection);
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    const char *sql = "SELECT ZDELETEDFLAG,ZHIDDEN,ZSORTMODE,ZSORTKEY,ZLASTMODIFICATION,ZTITLE,ZDETAILS FROM ZBKCOLLECTION WHERE ZCOLLECTIONID=? COLLATE BINARY ORDER BY Z_PK";
    if (sqlite3_prepare_v2(connection, sql, -1, &statement, NULL) != SQLITE_OK) {
        sqlite3_close_v2(connection);
        return nil;
    }
    sqlite3_bind_text(statement, 1, collectionID.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(statement) != SQLITE_ROW
        || sqlite3_column_type(statement, 0) != SQLITE_INTEGER
        || sqlite3_column_type(statement, 1) != SQLITE_INTEGER
        || sqlite3_column_type(statement, 2) != SQLITE_INTEGER
        || sqlite3_column_type(statement, 3) != SQLITE_INTEGER
        || (sqlite3_column_type(statement, 4) != SQLITE_FLOAT && sqlite3_column_type(statement, 4) != SQLITE_INTEGER)
        || sqlite3_column_type(statement, 5) != SQLITE_TEXT) {
        sqlite3_finalize(statement);
        sqlite3_close_v2(connection);
        return nil;
    }
    NSDictionary *result = @{
        @"deleted": @(sqlite3_column_int(statement, 0) != 0),
        @"hidden": @(sqlite3_column_int(statement, 1) != 0),
        @"sortMode": @(sqlite3_column_int64(statement, 2)),
        @"sortOrder": @(sqlite3_column_int64(statement, 3)),
        @"modificationDate": @(sqlite3_column_double(statement, 4)),
        @"title": ABText(statement, 5),
        @"details": ABText(statement, 6) ?: [NSNull null],
    };
    BOOL duplicate = sqlite3_step(statement) == SQLITE_ROW;
    sqlite3_finalize(statement);
    sqlite3_close_v2(connection);
    return duplicate ? nil : result;
}

static NSDictionary *ABReadCollectionMember(NSString *libraryDatabase, NSString *collectionID, NSString *assetID) {
    sqlite3 *connection = NULL;
    if (sqlite3_open_v2(libraryDatabase.fileSystemRepresentation, &connection, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || connection == NULL) {
        if (connection != NULL) sqlite3_close_v2(connection);
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    const char *sql = "SELECT M.ZSORTKEY,M.ZLOCALMODDATE FROM ZBKCOLLECTIONMEMBER M JOIN ZBKCOLLECTION C ON C.Z_PK=M.ZCOLLECTION WHERE C.ZCOLLECTIONID=? COLLATE BINARY AND M.ZASSETID=? COLLATE BINARY ORDER BY M.Z_PK";
    if (sqlite3_prepare_v2(connection, sql, -1, &statement, NULL) != SQLITE_OK) {
        sqlite3_close_v2(connection);
        return nil;
    }
    sqlite3_bind_text(statement, 1, collectionID.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, assetID.UTF8String, -1, SQLITE_TRANSIENT);
    int step = sqlite3_step(statement);
    if (step == SQLITE_DONE) {
        sqlite3_finalize(statement);
        sqlite3_close_v2(connection);
        return @{ @"present": @NO };
    }
    if (step != SQLITE_ROW
        || sqlite3_column_type(statement, 0) != SQLITE_INTEGER
        || (sqlite3_column_type(statement, 1) != SQLITE_FLOAT && sqlite3_column_type(statement, 1) != SQLITE_INTEGER)) {
        sqlite3_finalize(statement);
        sqlite3_close_v2(connection);
        return nil;
    }
    NSDictionary *result = @{
        @"present": @YES,
        @"sortOrder": @(sqlite3_column_int64(statement, 0)),
        @"modificationDate": @(sqlite3_column_double(statement, 1)),
    };
    BOOL duplicate = sqlite3_step(statement) == SQLITE_ROW;
    sqlite3_finalize(statement);
    sqlite3_close_v2(connection);
    return duplicate ? nil : result;
}

static BOOL ABUpsertCollectionDetail(id dataSource, NSDictionary *state, NSString *collectionID) {
    Class immutableClass = NSClassFromString(@"BCCollectionDetail");
    Class mutableClass = NSClassFromString(@"BCMutableCollectionDetail");
    id manager = ABCreateDataManager(dataSource, @"BCCollectionDetail", @"BCCloudCollectionDetailManagerChanged", immutableClass, mutableClass);
    if (manager == nil) return NO;
    id detail = ABAllocateWithObject(mutableClass, @"initWithCollectionID:", collectionID);
    if (detail == nil) return NO;
    ABSetObject(detail, @"setName:", state[@"title"]);
    id details = state[@"details"];
    ABSetObject(detail, @"setCollectionDescription:", details == [NSNull null] ? nil : details);
    ABSetBool(detail, @"setHidden:", [state[@"hidden"] boolValue]);
    ABSetInteger(detail, @"setSortMode:", [state[@"sortMode"] longLongValue]);
    ABSetInteger(detail, @"setSortOrder:", [state[@"sortOrder"] longLongValue]);
    ABSetObject(detail, @"setModificationDate:", [NSDate dateWithTimeIntervalSinceReferenceDate:[state[@"modificationDate"] doubleValue]]);
    return ABSetCloudData(
        manager,
        immutableClass,
        collectionID,
        @"collectionID",
        detail,
        [NSPredicate predicateWithFormat:@"collectionID == %@", collectionID]
    );
}

static BOOL ABDeleteCollectionAndMembers(id dataSource, NSString *collectionID) {
    Class detailClass = NSClassFromString(@"BCCollectionDetail");
    Class mutableDetailClass = NSClassFromString(@"BCMutableCollectionDetail");
    Class memberClass = NSClassFromString(@"BCCollectionMember");
    Class mutableMemberClass = NSClassFromString(@"BCMutableCollectionMember");
    id detailManager = ABCreateDataManager(dataSource, @"BCCollectionDetail", @"BCCloudCollectionDetailManagerChanged", detailClass, mutableDetailClass);
    id memberManager = ABCreateDataManager(dataSource, @"BCCollectionMember", @"BCCloudCollectionMemberManagerChanged", memberClass, mutableMemberClass);
    if (detailManager == nil || memberManager == nil) return NO;
    NSPredicate *memberPredicate = [NSPredicate predicateWithFormat:@"collectionMemberID BEGINSWITH %@", [collectionID stringByAppendingString:@"|"]];
    NSPredicate *detailPredicate = [NSPredicate predicateWithFormat:@"collectionID == %@", collectionID];
    return ABDeleteCloudData(memberManager, memberPredicate) && ABDeleteCloudData(detailManager, detailPredicate);
}

int32_t ABProjectCollectionState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_library_database_path,
    const char *collection_id
) {
    @autoreleasepool {
        if (root_path == NULL || canonical_cloud_database_path == NULL || canonical_library_database_path == NULL || collection_id == NULL) return 1;
        NSString *root = [NSString stringWithUTF8String:root_path];
        NSString *cloudDatabase = [NSString stringWithUTF8String:canonical_cloud_database_path];
        NSString *libraryDatabase = [NSString stringWithUTF8String:canonical_library_database_path];
        NSString *collectionID = [NSString stringWithUTF8String:collection_id];
        if (root == nil || cloudDatabase == nil || libraryDatabase == nil || collectionID.length == 0 || !ABIsRegularFile(libraryDatabase)) return 1;
        if (!ABLayoutIsExact(root, cloudDatabase, @"BCCloudCollections")) return 2;
        NSDictionary *state = ABReadCollection(libraryDatabase, collectionID);
        if (state == nil) return 3;
        if (dlopen("/System/Library/PrivateFrameworks/BookDataStore.framework/BookDataStore", RTLD_NOW) == NULL) return 4;
        Class owner = NSClassFromString(@"BCCloudCollectionsManager");
        id dataSource = ABCreateDataSource(root, @"BCCloudCollections", @"BCCloudCollections", owner);
        if (dataSource == nil || !ABLayoutIsExact(root, cloudDatabase, @"BCCloudCollections")) return 5;
        BOOL success = [state[@"deleted"] boolValue]
            ? ABDeleteCollectionAndMembers(dataSource, collectionID)
            : ABUpsertCollectionDetail(dataSource, state, collectionID);
        if (!success || !ABLayoutIsExact(root, cloudDatabase, @"BCCloudCollections")) return 6;
        if (![state[@"deleted"] boolValue] && ABExactRowCount(cloudDatabase, @"ZBCCOLLECTIONDETAIL", @"ZCOLLECTIONID", collectionID) != 1) return 7;
        return 0;
    }
}

int32_t ABProjectCollectionMemberState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_library_database_path,
    const char *collection_id,
    const char *asset_id
) {
    @autoreleasepool {
        if (root_path == NULL || canonical_cloud_database_path == NULL || canonical_library_database_path == NULL || collection_id == NULL || asset_id == NULL) return 1;
        NSString *root = [NSString stringWithUTF8String:root_path];
        NSString *cloudDatabase = [NSString stringWithUTF8String:canonical_cloud_database_path];
        NSString *libraryDatabase = [NSString stringWithUTF8String:canonical_library_database_path];
        NSString *collectionID = [NSString stringWithUTF8String:collection_id];
        NSString *assetID = [NSString stringWithUTF8String:asset_id];
        if (root == nil || cloudDatabase == nil || libraryDatabase == nil || collectionID.length == 0 || assetID.length == 0 || !ABIsRegularFile(libraryDatabase)) return 1;
        if (!ABLayoutIsExact(root, cloudDatabase, @"BCCloudCollections")) return 2;
        NSDictionary *state = ABReadCollectionMember(libraryDatabase, collectionID, assetID);
        if (state == nil) return 3;
        if (dlopen("/System/Library/PrivateFrameworks/BookDataStore.framework/BookDataStore", RTLD_NOW) == NULL) return 4;
        Class owner = NSClassFromString(@"BCCloudCollectionsManager");
        Class immutableClass = NSClassFromString(@"BCCollectionMember");
        Class mutableClass = NSClassFromString(@"BCMutableCollectionMember");
        id dataSource = ABCreateDataSource(root, @"BCCloudCollections", @"BCCloudCollections", owner);
        id manager = ABCreateDataManager(dataSource, @"BCCollectionMember", @"BCCloudCollectionMemberManagerChanged", immutableClass, mutableClass);
        if (dataSource == nil || manager == nil || !ABLayoutIsExact(root, cloudDatabase, @"BCCloudCollections")) return 5;
        NSString *memberID = [NSString stringWithFormat:@"%@|%@", collectionID, assetID];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"collectionMemberID == %@", memberID];
        BOOL success;
        if ([state[@"present"] boolValue]) {
            id member = ABAllocateWithObject(mutableClass, @"initWithCollectionMemberID:", memberID);
            if (member == nil) return 6;
            ABSetInteger(member, @"setSortOrder:", [state[@"sortOrder"] longLongValue]);
            ABSetObject(member, @"setModificationDate:", [NSDate dateWithTimeIntervalSinceReferenceDate:[state[@"modificationDate"] doubleValue]]);
            success = ABSetCloudData(manager, immutableClass, memberID, @"collectionMemberID", member, predicate);
        } else {
            success = ABDeleteCloudData(manager, predicate);
        }
        if (!success || !ABLayoutIsExact(root, cloudDatabase, @"BCCloudCollections")) return 7;
        if ([state[@"present"] boolValue] && ABExactRowCount(cloudDatabase, @"ZBCCOLLECTIONMEMBER", @"ZCOLLECTIONMEMBERID", memberID) != 1) return 8;
        return 0;
    }
}

static NSDictionary *ABReadAnnotationTarget(NSString *annotationsDatabase, NSString *assetID, NSString *annotationUUID) {
    sqlite3 *connection = NULL;
    if (sqlite3_open_v2(annotationsDatabase.fileSystemRepresentation, &connection, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK || connection == NULL) {
        if (connection != NULL) sqlite3_close_v2(connection);
        return nil;
    }
    const char *sql = "SELECT ZANNOTATIONDELETED,ZANNOTATIONMODIFICATIONDATE,ZANNOTATIONNOTE,ZFUTUREPROOFING6,ZANNOTATIONTYPE FROM ZAEANNOTATION WHERE ZANNOTATIONASSETID=? COLLATE BINARY AND ZANNOTATIONUUID=? COLLATE BINARY ORDER BY Z_PK";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(connection, sql, -1, &statement, NULL) != SQLITE_OK) {
        sqlite3_close_v2(connection);
        return nil;
    }
    sqlite3_bind_text(statement, 1, assetID.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, annotationUUID.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(statement) != SQLITE_ROW
        || sqlite3_column_type(statement, 0) != SQLITE_INTEGER
        || (sqlite3_column_type(statement, 1) != SQLITE_FLOAT && sqlite3_column_type(statement, 1) != SQLITE_INTEGER)
        || sqlite3_column_type(statement, 4) != SQLITE_INTEGER
        || sqlite3_column_int64(statement, 4) == 3) {
        sqlite3_finalize(statement);
        sqlite3_close_v2(connection);
        return nil;
    }
    id note = ABText(statement, 2) ?: [NSNull null];
    id userModificationDate = ABText(statement, 3) ?: [NSNull null];
    NSDictionary *result = @{
        @"uuid": annotationUUID,
        @"deleted": @(sqlite3_column_int(statement, 0) != 0),
        @"modified": @(sqlite3_column_double(statement, 1)),
        @"note": note,
        @"fp6": userModificationDate,
    };
    BOOL duplicate = sqlite3_step(statement) == SQLITE_ROW;
    sqlite3_finalize(statement);
    sqlite3_close_v2(connection);
    return duplicate ? nil : result;
}

static BOOL ABUpdateExistingAnnotationCloudObject(id cloudObject, NSDictionary *row) {
    NSData *raw = ((id (*)(id, SEL))objc_msgSend)(cloudObject, NSSelectorFromString(@"bookAnnotations"));
    if (![raw isKindOfClass:[NSData class]]) return NO;
    Class bookClass = NSClassFromString(@"BCAnnotationsProtoBook");
    id book = ((id (*)(id, SEL))objc_msgSend)(bookClass, sel_registerName("alloc"));
    book = ((id (*)(id, SEL, id))objc_msgSend)(book, NSSelectorFromString(@"initWithData:"), raw);
    if (book == nil) return NO;
    NSArray *annotations = ((id (*)(id, SEL))objc_msgSend)(book, NSSelectorFromString(@"annotations"));
    id target = nil;
    for (id annotation in annotations) {
        NSString *uuid = ((id (*)(id, SEL))objc_msgSend)(annotation, NSSelectorFromString(@"uuid"));
        if ([uuid isEqualToString:row[@"uuid"]]) {
            if (target != nil) return NO;
            target = annotation;
        }
    }
    if (target == nil) return NO;
    id note = row[@"note"];
    if (note != [NSNull null]) ABSetObject(target, @"setNote:", note);
    ABSetBool(target, @"setDeleted:", [row[@"deleted"] boolValue]); ABSetBool(target, @"setHasDeleted:", YES);
    ABSetDouble(target, @"setModificationDate:", [row[@"modified"] doubleValue]);
    id fp6 = row[@"fp6"];
    if (fp6 != [NSNull null]) { ABSetDouble(target, @"setUserModificationDate:", [fp6 doubleValue]); ABSetBool(target, @"setHasUserModificationDate:", YES); }
    NSData *updated = ((id (*)(id, SEL))objc_msgSend)(book, NSSelectorFromString(@"data"));
    if (![updated isKindOfClass:[NSData class]]) return NO;
    ABSetObject(cloudObject, @"setBookAnnotations:", updated);
    return YES;
}

int32_t ABProjectAnnotationState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_annotations_database_path,
    const char *asset_id,
    const char *annotation_uuid
) {
    @autoreleasepool {
        if (root_path == NULL || canonical_cloud_database_path == NULL || canonical_annotations_database_path == NULL || asset_id == NULL || annotation_uuid == NULL) return 1;
        NSString *root = [NSString stringWithUTF8String:root_path];
        NSString *cloudDatabase = [NSString stringWithUTF8String:canonical_cloud_database_path];
        NSString *annotationsDatabase = [NSString stringWithUTF8String:canonical_annotations_database_path];
        NSString *assetID = [NSString stringWithUTF8String:asset_id];
        NSString *annotationUUID = [NSString stringWithUTF8String:annotation_uuid];
        if (root == nil || cloudDatabase == nil || annotationsDatabase == nil || assetID.length == 0 || annotationUUID.length == 0 || !ABIsRegularFile(annotationsDatabase)) return 1;
        if (!ABLayoutIsExact(root, cloudDatabase, @"BCAssetData")) return 2;
        NSDictionary *target = ABReadAnnotationTarget(annotationsDatabase, assetID, annotationUUID);
        if (target == nil) return 3;
        if (dlopen("/System/Library/PrivateFrameworks/BookDataStore.framework/BookDataStore", RTLD_NOW) == NULL) return 4;
        Class owner = NSClassFromString(@"BCCloudAssetAnnotationManager");
        Class immutableClass = NSClassFromString(@"BCAssetAnnotations");
        Class mutableClass = NSClassFromString(@"BCMutableAssetAnnotations");
        id dataSource = ABCreateDataSource(root, @"BCAssetData", @"BCAssetData", owner);
        id manager = ABCreateDataManager(dataSource, @"BCAssetAnnotations", @"BCCloudAssetAnnotationManagerChanged", immutableClass, mutableClass);
        if (dataSource == nil || manager == nil || !ABLayoutIsExact(root, cloudDatabase, @"BCAssetData")) return 5;
        if (ABExactRowCount(cloudDatabase, @"ZBCASSETANNOTATIONS", @"ZASSETID", assetID) != 1) return 6;
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"assetID == %@", assetID];
        id cloudObject = ((id (*)(id, SEL, id, id))objc_msgSend)(manager, NSSelectorFromString(@"mutableCloudDataWithPredicate:sortDescriptors:"), predicate, @[]);
        if (cloudObject == nil || !ABUpdateExistingAnnotationCloudObject(cloudObject, target)) return 7;
        if (!ABSetCloudData(manager, immutableClass, assetID, @"assetID", cloudObject, predicate)) return 8;
        if (!ABLayoutIsExact(root, cloudDatabase, @"BCAssetData")) return 9;
        return ABExactRowCount(cloudDatabase, @"ZBCASSETANNOTATIONS", @"ZASSETID", assetID) == 1 ? 0 : 10;
    }
}
