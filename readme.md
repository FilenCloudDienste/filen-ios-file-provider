<br/>
<p align="center">
  <h3 align="center">Filen iOS File Provider Extension</h3>

  <p align="center">
    Used in <a href="https://github.com/FilenCloudDienste/filen-mobile">filen-mobile</a> as part of the mobile app
    <br/>
    <br/>
  </p>
</p>

![Contributors](https://img.shields.io/github/contributors/FilenCloudDienste/filen-ios-file-provider?color=dark-green) ![Forks](https://img.shields.io/github/forks/FilenCloudDienste/filen-ios-file-provider?style=social) ![Stargazers](https://img.shields.io/github/stars/FilenCloudDienste/filen-ios-file-provider?style=social) ![Issues](https://img.shields.io/github/issues/FilenCloudDienste/filen-ios-file-provider) ![License](https://img.shields.io/github/license/FilenCloudDienste/filen-ios-file-provider)

[iOS File Provider Extension Reference](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)

The extension is a **replicated** provider (`NSFileProviderReplicatedExtension`): the system keeps
its own copy of the hierarchy on disk and asks this extension for metadata, content, and changes.
The containing app has to register a domain with `NSFileProviderManager.add(_:)` before the system
will instantiate it — a replicated extension has no implicit default domain.

## Building
1) Place [filen-rs](https://github.com/FilenCloudDienste/filen-rs) next to the root of this object
2) Copy .env.example to .env and fill it out with relevant account details for a test account
3) Run either target depending on what you want to debug

## Testing

`FilenFileProviderTests` is a host-less unit test bundle driving the enumerators, the item lookup,
the modify dispatch and the cache FFI directly, without the system in the loop. It runs against the
live backend, so it needs the same test account as above.

The extension itself does run in the simulator (verified on iOS 26.5): build and run the
`FilenFileProvider` host app, flip its toggle, and it provisions the DEK, seals an auth.json,
registers the `io.filen.drive` domain and lists the drive root through a coordinated read. Pass
`-harness-enable` / `-harness-disable` as launch arguments to drive the same paths from a script.
A freshly registered domain starts out disabled by the user (`Enabled = false` in the system's
`Domains.plist`), and every request then fails with `NSFileProviderErrorDomainDisabled` (-2011)
until the location is switched on in Files.app.

```sh
./run-tests.sh                                   # uses ./.env
FILEN_TEST_ENV=/path/to/.env ./run-tests.sh      # or point elsewhere
FILEN_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16' ./run-tests.sh
```

In CI there is usually no `.env` — export `EMAIL`, `MASTER_KEYS`, `API_KEY`, `PRIVATE_KEY`,
`AUTH_VERSION` and `BASE_FOLDER_UUID` from your secret store instead and the script picks them up
directly. Both the shell (`KEY=value`) and xcconfig (`KEY = value`) spellings are accepted in the
file.

Without a session the tests skip rather than fail, so an unconfigured checkout stays green. Each
test creates a directory under the account's drive root and trashes it on teardown.


## License

Distributed under the AGPL-3.0 License. See [LICENSE](https://github.com/FilenCloudDienste/filen-ios-file-provider/blob/main/LICENSE) for more information.
