# Immutable keymap compatibility inputs

These files retain the original source bytes, including upstream comments.
Only the keymap entry modules and literal manifests are test inputs. Repository
build scripts are excluded and never run.

- `us`: [zigmkay/zigmkay_keycaprio_us_intl](https://github.com/zigmkay/zigmkay_keycaprio_us_intl/tree/9a3965c07cac85722817ef98da4f56335781a412),
  commit `9a3965c07cac85722817ef98da4f56335781a412`.
- `de`: [TrackingNina/ninikey_de](https://github.com/TrackingNina/ninikey_de/tree/9d7aff3b3b63dce75efcb670b606227b9dc3a1a8),
  commit `9d7aff3b3b63dce75efcb670b606227b9dc3a1a8`.

Both manifests pin firmware `c060ef3ab2dcc2c44724c1861a972407577fdd8c`.
Production analysis uses this application's unchanged immutable firmware pin.
See the [research evidence](../../../docs/design/keyboard-projects-and-import.md)
and [user guide](../../../docs/keyboard-projects.md).
