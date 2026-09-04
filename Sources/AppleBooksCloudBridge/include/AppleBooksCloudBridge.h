#ifndef APPLE_BOOKS_CLOUD_BRIDGE_H
#define APPLE_BOOKS_CLOUD_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t ABProjectCollectionState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_library_database_path,
    const char *collection_id
);

int32_t ABProjectCollectionMemberState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_library_database_path,
    const char *collection_id,
    const char *asset_id
);

int32_t ABProjectAnnotationState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_annotations_database_path,
    const char *asset_id,
    const char *annotation_uuid
);

#ifdef __cplusplus
}
#endif

#endif
