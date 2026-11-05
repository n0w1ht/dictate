# dictate.el: offline voice typing in Emacs

Press `C-c v`, speak, press `C-c v` again, and the words are typed where
the cursor was. It all runs on your own computer: ffmpeg records the
microphone and [NeMo-Speech](https://github.com/NVIDIA/NeMo-Speech.cpp)
turns each phrase into text with the
[Orukeet](https://huggingface.co/oruk/orukeet) model. No account, no
API key, no internet.

It works phrase by phrase: each time you pause, what you just said is
typed half a second or so later while you carry on talking.

Orukeet writes capitals and punctuation itself and knows 25 European
languages (English by default, see `dictate-language`). Because it
hears one phrase at a time, it ends every phrase with a full stop;
dictate takes that back when the next phrase follows a short pause, so
a sentence you pause in the middle of stays one sentence. Pause a little
longer (1.5 seconds) between sentences, or say "period".

## Install

1. Install ffmpeg, which records the microphone, with your package
   manager. On Windows run `winget install Gyan.FFmpeg`, then **restart
   Emacs** so it sees the new PATH.

2. On Windows, let desktop apps use the microphone: Settings > Privacy &
   security > Microphone > turn on **Let desktop apps access your
   microphone**. Without it ffmpeg records silence.

3. Download a release of
   [NeMo-Speech](https://github.com/NVIDIA/NeMo-Speech.cpp/releases) for
   your system (the `vulkan` build uses the graphics card on most
   machines; `cpu` works everywhere) and unpack it into `~/.nemo-speech/`.

4. Download `orukeet-v0.1.0-f16.gguf` from
   [oruk/orukeet](https://huggingface.co/oruk/orukeet/tree/main) into
   `~/.nemo-speech/models/`. Use this "native" GGUF, not the
   `transcribe-cpp` one, which is for a different program.

5. Copy `dictate.el` to `.emacs.d/lisp/` and add to your init file:

   ```elisp
   (use-package dictate
     :load-path "lisp/"
     :bind ("C-c v" . dictate-toggle)
     :custom
     ;; Both are found under ~/.nemo-speech/ when not set.
     (dictate-program "~/.nemo-speech/nemo-speech-0.3.0-linux-x86_64-vulkan/bin/nemo-speech")
     (dictate-model "~/.nemo-speech/models/orukeet-v0.1.0-f16.gguf"))
   ```

6. Run `M-x dictate-check`. Every line should start with `OK`. If you
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

### Sentences and pauses

| You say | You get |
|---|---|
| "the patient reports chest pain" (short pause) "and shortness of breath" | The patient reports chest pain and shortness of breath. |
| "she is stable" (1.5 s or more) "plan is discharge" | She is stable. Plan is discharge. |
| "she is stable period" (short pause) "plan is discharge" | She is stable. Plan is discharge. |

When phrases are joined, the first word of the second is written in
lower case, unless it is "I" or an acronym like ECG. A name at the
start of a joined phrase ("…seen by" pause "Smith") loses its capital
too; pause longer or fix it by hand. Set `dictate-sentence-pause` to nil
to keep every full stop the model writes.

If you would rather punctuate everything yourself, set
`dictate-punctuation` to `spoken`: the model then writes lower case
without punctuation, and only the marks you say are typed.

### Fixing what it gets wrong

| Command | Does |
|---|---|
| `M-x dictate-correct` | put point on a misheard word (or select a phrase), type what you meant: it is fixed there and in everything you dictate from now on |
| `M-x dictate-replay` | hear the phrase at point again (or the last one); run it again to stop |
| `M-x dictate-retranscribe` | transcribe the phrase at point again and replace its text, e.g. after adding a word to `dictate-vocabulary`; with `C-u`, say which language it was in |
| `M-x dictate-switch-language` | dictate the next phrases in the next language of `dictate-languages`; with `C-u`, pick any |

Corrections learnt with `dictate-correct` are kept in
`.emacs.d/dictate/corrections.eld`. They match whole words in any case,
and a correction to nothing drops a word, which is handy for "um". You
can also set them yourself:

```elisp
(setq dictate-corrections '(("troponine" . "troponin")
                            ("tug a" . "toggle")))
```

Corrections fix the text after the fact. To help the recognizer hear a
word right in the first place, add drug names, eponyms and
abbreviations to `dictate-vocabulary`:

```elisp
(setq dictate-vocabulary '("troponin" "Takotsubo" "apixaban"))
```

Replay and retranscribe need the audio, so the last 20 phrases are kept
(`dictate-recent-phrases`) in a temporary folder only you can read,
which is deleted when Emacs exits. If you dictate patient details, keep
that in mind; set `dictate-recent-phrases` to 0 to keep none.

### Several languages

Each phrase is transcribed on its own, so you can switch language in
the middle of a dictation and the next phrase is heard in the new one:

```elisp
(setq dictate-languages '("en" "fr"))
;; Switch by voice too: say "switch language" on its own.
(add-to-list 'dictate-commands '("switch language" dictate-switch-language))
```

The mode line then shows the language while you dictate.

### Your own steps

`dictate-text-functions` run on each phrase after the corrections and
before spoken commands. Each gets the text and returns the text to
type, or nil to drop the phrase:

```elisp
(add-hook 'dictate-text-functions
          (lambda (text) (replace-regexp-in-string "\\bmilligrams\\b" "mg" text)))
```

## Voice commands

Say a command on its own, with a short pause before and after it:

| Say | Does |
|---|---|
| new line / new paragraph | starts a new line / a new paragraph (these also work in the middle of a phrase: "stroke volume new line cardiac output") |
| delete that / scratch that / undo | deletes the last phrase typed; say it again to go further back |
| stop dictating | stops, like pressing `C-c v` |
| comma, period, full stop, question mark, exclamation mark | types that mark; also works as the last words of a phrase ("chest pain period") |
| colon, semicolon | types that mark, when said on its own |

A spoken mark replaces the one the model put at the end of the phrase,
so "chest pain period" gives one full stop, and "heart rate" (pause)
"comma" gives "heart rate,". A full stop you said is never taken back.

Only "new line" and "new paragraph" are recognised inside a phrase.
Comma, period, full stop, question mark and exclamation mark also work
at the end of a phrase, so a phrase that really ends in "time period"
is typed as "time.". The others count only when said on their own, so
"the colon absorbs water" is typed as it is. `M-x dictate-delete-last`
does the same as "delete that".

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
| `dictate-program` | nil | nemo-speech; nil finds it on PATH or under `~/.nemo-speech/` (newest release) |
| `dictate-model` | nil | `.gguf` model; nil uses the newest in `~/.nemo-speech/models/` |
| `dictate-nemo-directory` | `"~/.nemo-speech/"` | where the two above are looked for |
| `dictate-language` | `"en"` | language code; nil lets the model guess (poorly, on short phrases) |
| `dictate-punctuation` | `model` | `model` punctuates for you; `spoken` types only the marks you say |
| `dictate-sentence-pause` | 1.5 | seconds of pause that end a sentence; shorter pauses join phrases; nil never joins |
| `dictate-vocabulary` | nil | words the recognizer should favour |
| `dictate-corrections` | nil | (HEARD . MEANT) pairs fixed in every phrase, besides those learnt by `dictate-correct` |
| `dictate-corrections-file` | `.emacs.d/dictate/corrections.eld` | where `dictate-correct` keeps what it learns |
| `dictate-text-functions` | nil | functions that change each phrase before it is typed |
| `dictate-recent-phrases` | 20 | phrases whose audio is kept for replay and retranscribe; 0 keeps none |
| `dictate-play-program` | `"ffplay"` | plays a phrase (`dictate-play-args` are its arguments) |
| `dictate-languages` | `("en")` | languages `dictate-switch-language` goes through |
| `dictate-device` | nil | `"cpu"`, `"vulkan"`, `"cuda"`, `"metal"`; nil picks the graphics card when it can |
| `dictate-extra-args` | nil | more arguments for `nemo-speech transcribe` |
| `dictate-microphone` | nil | microphone name; nil uses the default |
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
  mic picks up fan noise and its own vibration.
- **Text comes out in another language**: set `dictate-language`.
- **Full stops in the middle of sentences**: you paused longer than
  `dictate-sentence-pause`; raise it to 2.0. **Sentences run together**:
  lower it, or say "period".
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
- **"nemo-speech failed: ..."**: the message ends with what nemo-speech
  said. Run `M-x dictate-check` to see which program and model are used.
  If the graphics card is the problem, set `dictate-device` to `"cpu"`.

Recording uses PulseAudio on GNU/Linux, DirectShow on Windows and
AVFoundation on macOS; set `dictate-microphone` or `dictate-input-args`
to choose another input.

## Tests

```
emacs -Q --batch -L . -l test/dictate-test.el -f ert-run-tests-batch-and-exit
```

The recording tests need ffmpeg; they read a file instead of the
microphone and use a fake nemo-speech. To use the real one, set
`DICTATE_TEST_NEMO` and `DICTATE_TEST_MODEL`, and `DICTATE_TEST_WAV`
to a recording of speech.
