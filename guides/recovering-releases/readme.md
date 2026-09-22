# Recovering Releases

This guide explains how to resume an interrupted publishing workflow using the original gem and its verification evidence.

Use this when a workflow fails during preservation, upload, registry propagation, or tag/release finalization. For failures while creating the PR, see [Preparing Releases](../preparing-releases/index). Publishing recovery retains the original source and artifact bytes.

## Rerun the original workflow

Use **Re-run all jobs** on the original publishing run, or:

``` bash
bundle exec bake gem:github:release:resume run=RUN_ID
```

Rerunning keeps the original event identity. GitHub may request publishing environment approval again. A retained artifact is downloaded and its source identity/digest checked. A matching registry version resumes tag/release finalization; different bytes or a conflicting tag stop. There is no automatic yank, retag, or rebuild of an already-published version. Registry propagation is retried every ten seconds for up to one minute; a digest or attestation mismatch fails immediately.

## Restore retained artifacts

Before uploading to RubyGems, the publisher stores the verified gem, receipt and both attestation bundles together in `release.tar`, uploaded as one draft-release asset before their individual assets. The draft targets the merged commit. It publishes the draft after registry verification and tag creation. Actions artifacts are also retained for 90 days, but can disappear on rerun. Recovery falls back to `release.tar` in the draft or published release, checking its digest and requiring exactly the four expected regular files before restoring them. It verifies the original bytes and attestations, then resumes any missing individual asset uploads. Older releases without an archive can still restore their four individual assets. Existing assets and backups are compared with the original files and never replaced with conflicting content.

## Handle incomplete preservation

A rerun can recover an interrupted individual asset upload once `release.tar` is available, even if the Actions artifact has disappeared. An available Actions artifact can also resume an interrupted archive upload. If neither backup completed, restore the missing original files manually; the publisher stops before uploading to RubyGems. Keep the draft until finalization succeeds. A published version is never rebuilt to fill a missing backup.

## Understand workflow reruns

GitHub concurrency does not guarantee a durable FIFO queue: rerun any publishing run displaced while pending. Resume reruns all jobs, including integrity checks; it does not repeat or second-guess the native review policy or a permitted administrator bypass. Older publishing runs execute their original code; adding this recovery support to the default branch does not change an already-triggered workflow.
