# Recording folder access

The recording destination is a platform-owned capability. The UI passes only
`RecordFolder.locator` from `RecordFolderStore` into the recording ABI. Never
interpret `content:` as a filesystem path. The name shown to the user is saved
separately from the locator. Cancellation keeps the previous choice; failed
write/read validation does not replace it. A saved but revoked/offline folder
stays selected and is shown as inaccessible until the user chooses another.

- Android: `RecordFolderPlugin` opens `ACTION_OPEN_DOCUMENT_TREE` from the
  Activity and takes the read/write persistable permission for the selected tree
  only. On each access check it creates, writes, seeks, reads and deletes a
  temporary document. The JNI `content` provider runs on the recorder writer
  thread, queries sibling names, creates a new document via
  `DocumentsContract.createDocument`, checks the actual name and seekability,
  then transfers the `ParcelFileDescriptor` fd to the native writer. SAF
  providers that rename collisions return `SDR_RECORD_EXISTS`; revoked access
  returns `SDR_RECORD_FOLDER_UNAVAILABLE`. Replacing a folder drops the old
  tree's persisted grant after saving the new choice; a rejected new tree's
  grant is dropped without changing the saved choice. No broad storage
  permission is used.
- Linux and Windows: `file_selector.getDirectoryPath` delegates to GTK and the
  Windows native file dialog. macOS uses `NSOpenPanel` directly and saves an
  app-scoped security bookmark in native preferences. On restart it resolves
  the bookmark and retains the scope for the native writer; a saved path alone
  never grants access in the sandbox. A real write/read/delete probe checks
  directory access before saving `file:<absolute path>`. The native writer,
  not Dart, must use exclusive creation and handle access loss after this check.

`test/platform/record_folder_test.dart` covers cancellation, persistence,
revocation and write/readback on a temporary Linux directory. The Android
channel adapter has mocked tests in `android_record_folder_test.dart`.
`integration_test/record_folder_emulator_test.dart` uses the real system picker
and SAF provider on an Android emulator: select a directory in the picker and
confirm access, then verify a real document write/readback and restored locator.
It then revokes the tree grant and verifies the saved locator stays selected
but is inaccessible until re-selection. The emulator test passed on API 35;
this is a same-process restore. A cold-process relaunch remains to be checked
by the integration/QA card.
Neither these tests nor a successful access check establish actual IQ/audio
recording: the native writer and UI use the folder capability in their own
cards. CI is configured to compile the macOS/Windows apps and exercise folder
adapters on their own runners, but that CI run and actual macOS/Windows
chooser/bookmark behavior remain unverified until the complete PR runs.
