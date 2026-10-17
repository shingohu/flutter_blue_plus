## Unreleased
* Fence service-dependent operations by service revision after native awaits, discard stale results, and let post-reset notifications load a fresh snapshot.
* Reject ambiguous primary/included notification owners and handles absent from the current snapshot.
* Serialize and share notification service loads; fence callbacks and queued operations by connection session.
* Prevent obsolete service queries from repopulating caches after Service Changed.
* Disambiguate duplicate service/characteristic UUIDs using handles on API 18+; reject ambiguous or invalid instances.

## 1.0.2
* 增加isSupport()接口

## 1.0.1
* 修复无法获取ManufactureData问题
* 修复使用Worker使用不当问题
* 修改advName获取方式
* 增加扫描蓝牙过滤条件

## 1.0.0
* Support OpenHarmony
