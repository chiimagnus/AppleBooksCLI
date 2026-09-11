#ifndef APPLE_BOOKS_CLOUD_BRIDGE_H
#define APPLE_BOOKS_CLOUD_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

extern const size_t ABCloudProjectionMaximumIdentityBytes;
extern const size_t ABCloudProjectionMaximumAnnotationNoteBytes;
extern const size_t ABCloudProjectionMaximumCollectionTitleBytes;
extern const size_t ABCloudProjectionMaximumCollectionDetailsBytes;
extern const size_t ABCloudProjectionMaximumFixedMetadataBytes;
extern const size_t ABCloudProjectionMaximumBookAnnotationsBytes;

int32_t ABProjectCollectionState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_library_database_path,
    const uint8_t *collection_id_bytes,
    size_t collection_id_length
);

int32_t ABProjectCollectionMemberState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_library_database_path,
    const uint8_t *collection_id_bytes,
    size_t collection_id_length,
    const uint8_t *asset_id_bytes,
    size_t asset_id_length
);

int32_t ABProjectAnnotationState(
    const char *root_path,
    const char *canonical_cloud_database_path,
    const char *canonical_annotations_database_path,
    const uint8_t *asset_id_bytes,
    size_t asset_id_length,
    const uint8_t *annotation_uuid_bytes,
    size_t annotation_uuid_length
);

#ifdef __cplusplus
}
#endif

#endif
