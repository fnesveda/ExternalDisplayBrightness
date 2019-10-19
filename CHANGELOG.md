Changelog
=========

[1.2.0](../../releases/tag/v1.2.0) - 2019-10-19
-----------------------------------------------
### Added
- support for listening to the brightness keys on the Magic Keyboard
- support for keeping the brightness changes even when the display powers off
### Fixed
- reading the maximum brightness from the display
- support for displays with serial number larger than or equal to 0x80000000
- relaunching the app when the path to the app contains a space
### Changed
- increased the minimum reply delay in I2C communication with the display to 40 milliseconds as per the DDC/CI standard, which could fix some freezes

[1.1.0](../../releases/tag/v1.1.0) - 2019-10-08
-----------------------------------------------
### Added
- support for changing the brightness of all connected displays simultaneously

[1.0.0](../../releases/tag/v1.0.0) - 2019-08-28
-----------------------------------------------
Initial release of the app.
