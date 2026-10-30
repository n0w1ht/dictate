# dictate.el: offline voice typing in Emacs

Press `C-c v`, speak, press `C-c v` again, and the words are typed where
the cursor was. It all runs on your own computer: ffmpeg records the
microphone and [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
turns the recording into text. No account, no API key, and no internet
after the first download.

Unlike Windows voice typing (Win+H), it doesn't depend on Emacs
supporting the Windows text service, so words don't get dropped. It
works phrase by phrase: each time you pause, what you just said is
typed a second or two later while you carry on talking.

## Install on Windows

1. Install ffmpeg (records the microphone), then **restart Emacs** so it
   sees the new PATH:

   ```
   winget install Gyan.FFmpeg
   ```

2. Let desktop apps use the microphone: Settings > Privacy & security >
   Microphone > turn on **Let desktop apps access your microphone**.
   Without it ffmpeg records silence.

3. Copy `dictate.el` to `.emacs.d/lisp/` and add to your init file:

   ```elisp
   (use-package dictate
     :load-path "lisp/"
     :bind ("C-c v" . dictate-toggle)
     :custom
     ;; Words you often say, so whisper spells them right (optional).
     (dictate-prompt "Medical school notes. Tachycardia, myocardial
   infarction, glomerular filtration rate, ACE inhibitors."))
   ```

4. Restart Emacs (or evaluate the block), then run `M-x dictate-setup`.
   It downloads whisper.cpp from its GitHub releases and the model you
   pick from Hugging Face into `.emacs.d/dictate/`, in the background.
   Pick **small.en** (466 MB): it is the best fit for medical words on a
   laptop. The mode line message says when it's done.

5. Run `M-x dictate-check`. Every line should start with `OK`. If you
   have more than one microphone (laptop mic, headset), run
   `M-x dictate-select-microphone` and pick one; to keep the choice, add
   the line it shows to your init file.

## Use

- `C-c v`: start dictating at the cursor. The mode line shows
  **● Listening**, and **● Hearing you** while you speak. When you pause
  (0.7 seconds), that phrase is typed while you go on with the next
  one. Press `C-c v` again to stop; the last phrase is typed then.
- Each phrase is given the one before it as context, so whisper keeps
  the sentence going. If it put a full stop at a pause in the middle
  of a sentence, the full stop is taken back when the next phrase
  carries on in lower case.
- `C-u C-c v`: ask which language you'll speak first (for example `hu`
  or `auto`). This needs a model without `.en` in its name, such as
  `small` or `large-v3-turbo-q5_0`; download one with `M-x dictate-setup`.
- `M-x dictate-cancel`: stop, and throw away whatever wasn't typed yet.
- It works in any buffer you can type in, including the minibuffer (a
  consult search, for example). In a read-only buffer (a PDF, the readq
  dashboard) the text goes to the kill ring instead; paste it with `C-y`.
- You can keep working while it transcribes. The text goes where the
  cursor was when you started (each phrase after the last), even if you
  moved.
- Text is fitted to its surroundings: a space is added where needed, and
  when you dictate into the middle of a sentence the first word is made
  lower case and whisper's full stop is dropped.
- Whisper writes the punctuation itself from how you speak; you don't
  say "comma" or "full stop".
- Recording stops on its own after 10 minutes (`dictate-max-seconds`).

## Voice commands

Say a command on its own, with a short pause before and after it:

| Say | Does |
|---|---|
| new line / new paragraph | starts a new line / a new paragraph (these also work in the middle of a phrase: "stroke volume new line cardiac output") |
| delete that / scratch that / undo | deletes the last phrase typed; say it again to go further back |
| stop dictating | stops, like pressing `C-c v` |
| comma, period, full stop, question mark, exclamation mark, colon, semicolon | types that mark, for when whisper leaves it out |

Only "new line" and "new paragraph" are recognised inside a phrase.
The others count only when said on their own, so "the colon absorbs
water" is typed as it is. `M-x dictate-delete-last` does the same as
"delete that".

Add your own in `dictate-commands`. Each entry is the words, then a
string to type or a function to call where the text goes, then t if it
should also work inside a phrase:

```elisp
(add-to-list 'dictate-commands
             '("new heading" (lambda () (insert "\n* "))))
```

## Models

`M-x dictate-setup` can download any of these; the newest one downloaded
is used (or set `dictate-model` to a file).

| Model | Size | Notes |
|---|---|---|
| tiny.en | 75 MB | fastest, more mistakes |
| base.en | 142 MB | fast, good for everyday English |
| small.en | 466 MB | recommended; good with medical words |
| medium.en | 1.5 GB | more accurate, slow on a laptop CPU |
| large-v3-turbo-q5_0 | 547 MB | many languages, accurate, slower |
| base, small | 142 / 466 MB | many languages |

If transcribing feels slow, switch to base.en. If it misspells terms,
add them to `dictate-prompt`.

## Settings

| Variable | Default | What it does |
|---|---|---|
| `dictate-language` | `"en"` | spoken language, or `"auto"` |
| `dictate-prompt` | nil | vocabulary and style hint for whisper |
| `dictate-microphone` | nil | microphone name; nil uses the first one |
| `dictate-model` | nil | model file; nil uses the newest download |
| `dictate-whisper-program` | nil | whisper-cli; nil finds it |
| `dictate-threads` | CPU cores, up to 8 | CPU threads for whisper |
| `dictate-live` | t | phrase by phrase; nil types everything after you stop |
| `dictate-live-pause` | 0.7 | seconds of quiet that end a phrase |
| `dictate-live-max-phrase` | 25 | longest phrase in seconds |
| `dictate-live-max-gap` | 5 | seconds of quiet sound before a phrase sent with it, so soft words are never lost |
| `dictate-live-sensitivity` | 3.0 | how much louder than background noise speech must be |
| `dictate-live-min-level` | 150 | quietest sound counted as speech |
| `dictate-live-show-level` | nil | show loudness/threshold in the mode line, for tuning |
| `dictate-smart-spacing` | t | fit spaces and capitals to the text around |
| `dictate-max-seconds` | 600 | longest recording |
| `dictate-keep-audio` | nil | keep the last recording as `.emacs.d/dictate/last.wav` |
| `dictate-commands` | see above | spoken commands |
| `dictate-after-insert-hook` | nil | functions run with the start and end of the text |

## If something goes wrong

- **"nothing was recorded: ... Could not find audio only device"**: the
  microphone name is wrong. Run `M-x dictate-select-microphone`.
- **"heard nothing"** every time: check the microphone permission in
  step 2, and that the right microphone is picked. Set
  `dictate-keep-audio` to t and play `.emacs.d/dictate/last.wav` to hear
  what was recorded.
- **Phrases never end, or end in the middle of words**: turn on
  `dictate-live-show-level` and watch the two numbers in the mode
  line. The first (loudness) should be above the second (threshold)
  while you speak and below it in pauses. With a noisy fan or room,
  raise `dictate-live-sensitivity` or `dictate-live-min-level`; if quiet
  speech is missed, lower them. If you pause a lot mid-sentence, raise
  `dictate-live-pause` to 1.0.
- **Each phrase takes a while to appear**: whisper loads the model for
  every phrase, which costs about a second with small.en. Use base.en
  for a snappier feel.
- **"Thank you." appears when you said nothing**: whisper does this on
  silence. Stop sooner after you finish speaking.
- **dictate-setup fails while downloading**: download by hand instead.
  Get `whisper-bin-x64.zip` from the
  [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases/latest)
  and unzip it into `.emacs.d/dictate/whisper/`; get
  `ggml-small.en.bin` from
  [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/tree/main)
  into `.emacs.d/dictate/models/`.

## On GNU/Linux and macOS

Install ffmpeg and whisper.cpp with your package manager (or build
whisper.cpp), then run `M-x dictate-setup` for the model. Recording uses
PulseAudio on GNU/Linux and AVFoundation on macOS; set
`dictate-microphone` or `dictate-input-args` to choose another input.

## Tests

```
emacs -Q --batch -L . -l test/dictate-test.el -f ert-run-tests-batch-and-exit
```

The recording tests need ffmpeg; they read a file instead of the
microphone and use a fake whisper-cli.
