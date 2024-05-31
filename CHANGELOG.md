# Change log for foundryvtt-azure

The format is based on and uses the types of changes according to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2024-06-01

### Added

- Added support for P0V3 App Service Plan SKU in Bicep.

### Fixed

- Prevent duplicate Azure deployment names.

## [0.4.0] - 2022-11-07

### Changed

- Change default App Service Plan to P1V2.
- Converted App Service plan SKU to B3 and added support for B2 & B3.

## [0.3.0] - 2022-10-14

### Changed

- Converted workflow to use Workload Identity Federation.

## [0.2.0] - 2021-08-20

### Added

- Added support for deploying to App Service Plans.

### Changed

- Changed the container start up limit in the Web App deployment to 1800 seconds (maximum) to account for additional start-up time with many modules.
- Reduced default file share size to 100 GB and eliminated silly sizes.
