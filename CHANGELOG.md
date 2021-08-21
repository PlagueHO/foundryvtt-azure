# Change log for foundryvtt-azure

The format is based on and uses the types of changes according to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2020-08-20

### Added

- Added support for deploying to App Service Plans.

### Changed

- Changed the container start up limit in the Web App deployment to 1800 seconds (maximum) to account for additional start-up time with many modules.
