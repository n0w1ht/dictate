# dictate.el: offline voice typing in Emacs

Press `C-c v`, speak, press `C-c v` again, and the words are typed where
the cursor was. It all runs on your own computer: ffmpeg records the
microphone and [parakeet.cpp](https://github.com/mudler/parakeet.cpp),
which runs NVIDIA's Parakeet speech models, turns the recording into
text. No account, no API key, no internet.

Unlike Windows voice typing (Win+H), it doesn't depend on Emacs
supporting the Windows text service, so words don't get dropped. It
works phrase by phrase: each time you pause, what you just said is
typed a second or two later while you carry on talking.

The Parakeet CTC models (`ctc-0.6b`, `ctc-1.1b`) understand English
only, and write lower case without punctuation. dictate starts each
sentence and line with a capital and writes "i" as "I"; you say
"period", "comma" or "question mark" at the end of a phrase.

## Install

1. Install ffmpeg, which records the microphone. On Windows run
   `winget install Gyan.FFmpeg`, then **restart Emacs** so it sees the
   new PATH; on GNU/Linux and macOS use your package manager.

2. On Windows, let desktop apps use the microphone: Settings > Privacy &
   security > Microphone > turn on **Let desktop apps access your
   microphone**. Without it ffmpeg records silence.

3. Download a release of
   [parakeet.cpp](https://github.com/mudler/parakeet.cpp/releases) for
   your system and a `.gguf` CTC model (`ctc-1.1b-f16.gguf` is the most
   accurate) into `~/.parakeet/`.

4. Copy `dictate.el` to `.emacs.d/lisp/` and add to your init file:

   ```elisp
   (use-package dictate
     :load-path "lisp/"
     :bind ("C-c v" . dictate-toggle)
     :custom
     ;; Both are found under ~/.parakeet/ when not set.
     (dictate-parakeet-program "~/.parakeet/parakeet-v0.6.1-bin-linux-vulkan-x64/parakeet-cli")
     (dictate-parakeet-model "~/.parakeet/ctc-1.1b-f16.gguf"))
   ```

5. Run `M-x dictate-check`. Every line should start with `OK`. If you
   have more than one microphone (laptop mic, headset), run
   `M-x dictate-select-microphone` and pick one; to keep the choice, add
   the line it shows to your init file.

## Use

- `C-c v`: start dictating at the cursor. The mode line shows
  **● Listening**, and **● Hearing you** while you speak. When you pause
  (0.7 seconds), that phrase is typed while you go on with the next
  one. Press `C-c v` again to stop; the last phrase is typed then.
- `M-x dictate-cancel`: stop, and throw away whatever wasn't typed yet.
- It works in any buffer you can type in, including the minibuffer (a
  consult search, for example). In a read-only buffer (a PDF, the readq
  dashboard) the text goes to the kill ring instead; paste it with `C-y`.
- You can keep working while it transcribes. The text goes where the
  cursor was when you started (each phrase after the last), even if you
  moved.
- Text is fitted to its surroundings: a space is added where needed, a
  new sentence or line starts with a capital, and when you dictate into
  the middle of a sentence the first word stays lower case.
- Recording stops on its own after 10 minutes (`dictate-max-seconds`).

## Voice commands

Say a command on its own, with a short pause before and after it:

| Say | Does |
|---|---|
| new line / new paragraph | starts a new line / a new paragraph (these also work in the middle of a phrase: "stroke volume new line cardiac output") |
| delete that / scratch that / undo | deletes the last phrase typed; say it again to go further back |
| stop dictating | stops, like pressing `C-c v` |
| comma, period, full stop, question mark, exclamation mark | types that mark; also works as the last words of a phrase ("chest pain period") |
| colon, semicolon | types that mark, when said on its own |

Only "new line" and "new paragraph" are recognised inside a phrase.
Comma, period, full stop, question mark and exclamation mark also work
at the end of a phrase, so a phrase that really ends in "time period"
is typed as "time.". The others count only when said on their own, so
"the colon absorbs water" is typed as it is. `M-x dictate-delete-last` does the same as
"delete that".

Add your own in `dictate-commands`. Each entry is the words, then a
string to type or a function to call where the text goes, then t if it
should also work inside a phrase, or `end` if it should also work as
the last words of one:

```elisp
(add-to-list 'dictate-commands
             '("new heading" (lambda () (insert "\n* "))))
```

## Settings

| Variable | Default | What it does |
|---|---|---|
| `dictate-parakeet-program` | nil | parakeet-cli; nil finds it on PATH or under `~/.parakeet/` |
| `dictate-parakeet-model` | nil | `.gguf` model; nil uses the newest under `~/.parakeet/` |
| `dictate-parakeet-directory` | `"~/.parakeet/"` | where the two above are looked for |
| `dictate-parakeet-extra-args` | nil | more arguments for `parakeet-cli transcribe` |
| `dictate-microphone` | nil | microphone name; nil uses the first one |
| `dictate-live` | t | phrase by phrase; nil types everything after you stop |
| `dictate-live-pause` | 0.7 | seconds of quiet that end a phrase |
| `dictate-live-max-phrase` | 25 | longest phrase in seconds |
| `dictate-live-max-gap` | 5 | seconds of quiet sound before a phrase sent with it, so soft words are never lost |
| `dictate-live-sensitivity` | 3.0 | how much louder than background noise speech must be |
| `dictate-live-min-level` | 150 | quietest sound counted as speech |
| `dictate-live-show-level` | nil | show loudness/threshold in the mode line, for tuning |
| `dictate-audio-filter` | `"highpass=f=100"` | ffmpeg filter on the mic; the default cuts low rumble (fans, hum) |
| `dictate-smart-spacing` | t | fit spaces and capitals to the text around |
| `dictate-max-seconds` | 600 | longest recording |
| `dictate-keep-audio` | nil | keep the last recording as `last.wav` in `dictate-directory` (`.emacs.d/dictate/`) |
| `dictate-commands` | see above | spoken commands |
| `dictate-after-insert-hook` | nil | functions run with the start and end of the text |

## If something goes wrong

- **Transcripts are poor**: use a headset or a mic close to your mouth
  if you have one; `M-x dictate-select-microphone` picks it (on
  GNU/Linux it lists PulseAudio/PipeWire sources). A laptop's built-in
  mic picks up fan noise and its own vibration. Also check the input
  level is not too high (see below).
- **"nothing was recorded: ... Could not find audio only device"**: the
  microphone name is wrong. Run `M-x dictate-select-microphone`.
- **"heard nothing"** every time: check the microphone permission
  (Windows, step 2), and that the right microphone is picked. Set
  `dictate-keep-audio` to t and play `.emacs.d/dictate/last.wav` to hear
  what was recorded.
- **Phrases never end, or end in the middle of words**: turn on
  `dictate-live-show-level` and watch the two numbers in the mode
  line. The first (loudness) should be above the second (threshold)
  while you speak and below it in pauses. With a noisy fan or room,
  raise `dictate-live-sensitivity` or `dictate-live-min-level`; if quiet
  speech is missed, lower them. If you pause a lot mid-sentence, raise
  `dictate-live-pause` to 1.0.
- **"parakeet failed: ..."**: the message ends with what parakeet-cli
  said. Run `M-x dictate-check` to see which program and model are used.

Recording uses DirectShow on Windows, PulseAudio on GNU/Linux and
AVFoundation on macOS; set `dictate-microphone` or `dictate-input-args`
to choose another input.

## Tests

```
emacs -Q --batch -L . -l test/dictate-test.el -f ert-run-tests-batch-and-exit
```

The recording tests need ffmpeg; they read a file instead of the
microphone and use a fake parakeet-cli. To use the real one, set
`DICTATE_TEST_PARAKEET` and `DICTATE_TEST_MODEL`, and `DICTATE_TEST_WAV`
to a recording of speech.
