# WavNotes

Drop WAV files (or folders) onto the window. For each file it takes the first 10 seconds,
mixes all channels to mono, transcribes with Whisper (whisper.cpp), and writes the text into
the iXML `<NOTE>` field, the "Notes" column in Wave Agent, Soundminer, Pro Tools, Resolve and similar tools.

## Download

Grab `WavNotes.zip` from the [Releases](https://github.com/zgoheen/WavNotes/releases) page, unzip, and move
`WavNotes.app` to Applications. The app isn't notarized, so the first time, right-click it › **Open** (or run
`xattr -dr com.apple.quarantine /Applications/WavNotes.app`).

## Build

```bash
./build_app.sh        # -> build/WavNotes.app
```

Requires macOS 14+ and Xcode 15.4+. Runs on Intel and Apple Silicon.

## Using it

- Drop files/folders on the window, on the Dock icon, use **Add Files…**, or Finder › Open With.
- Review/edit the transcripts, then **Write Notes to Files** (⌘↩). Or tick *Write automatically*.
- Models download on first use to `~/Library/Application Support/WavNotes/models`.
- Files with no speech (SFX, room tone) are flagged and never written, so an existing note is not wiped.

## Command line

```bash
build/WavNotes.app/Contents/MacOS/WavNotes --cli [--model tiny|base|small|largeTurbo] [--lang auto|en] [--dry-run] *.wav
build/WavNotes.app/Contents/MacOS/WavNotes --cli --set-note "Scene 12A take 3" file.wav
```

## How the file is edited (in place, audio never rewritten)

| Situation | What happens |
|---|---|
| No iXML chunk | New iXML chunk appended at the end |
| iXML is the last chunk | Tail rewritten |
| iXML mid-file, new XML fits | Overwritten in place, padded with whitespace |
| iXML mid-file, doesn't fit | Old chunk renamed `JUNK`, new iXML appended |

Other iXML fields are preserved; only `<NOTE>` is replaced (or added). RIFF and RF64/BW64 are supported.

## Credits

Transcription by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT); its prebuilt v1.9.2 macOS
framework is vendored in `Frameworks/` with its license alongside.
