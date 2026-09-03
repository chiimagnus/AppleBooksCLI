#ifndef APPLE_BOOKS_CLOUD_BRIDGE_H
#define APPLE_BOOKS_CLOUD_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t ABProjectCollectionDetail(
    const char *root_path,
    const char *canonical_database_path,
    const char *collection_id,
    const char *title,
    int64_t sort_order,
    double modification_date_reference_seconds
);

#ifdef __cplusplus
}
#endif

#endif
