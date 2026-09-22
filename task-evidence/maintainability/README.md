# Recording file cleanup runtime evidence

Synthetic audio and project data only. Captured2026-09-21.

Mobile commit d24ce964357618ae5605a6ee43ac9049c78c64f8; Maccommit b15d28b917d061c0b50b7ef9a4e6b43ba33cd6a8. Android screenshot comes from worker6ffb53246eee4afd162e807ec2a794b5a8934144; its android/app tree is identical to the final mobile tree. Isolated QA package com.rhymeai.app.recordingsqa on existing emulator5580. Shows imported20second recording retained after relaunch, alongside existing synthetic rows. Built/installedAPK SHA2563bd8cffaf040fae450d0b31731c37456844373406496b120516d556af7e7c531.

mac-runtime.log is unedited output from a locally compiled actual-production-service driver at exactMaccommit. It exercises real decoder/file storage/backup manifest logic, with originalbyte retention, duplicate/two-song isolation, rename/trash/restore, invalidimport cleanup and whitespace normalization. Process exited0. NoMacGUI, microphone/acousticplayback or livecloud proof.

Integrated checks: Android252tests/5skips/0failures, build/lintpass; iOS76tests/fivesuites pass; nativeMacbuild-for-testing pass. Detailed local invocations/manifests are attached to the task and summarized in the PR; these captures alone do not establish broader acceptance.
