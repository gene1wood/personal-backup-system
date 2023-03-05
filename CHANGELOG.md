# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2023-03-04

### Added

- Support for write-only backup by detecting if existing files can be modified/deleted
  and if not, skip pruning
- Logging of the current backup directory contents with each run

[unreleased]: https://github.com/gene1wood/personal-backup-system/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/gene1wood/personal-backup-system/releases/tag/v1.0.0
