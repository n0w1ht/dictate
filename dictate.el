;;; dictate.el --- Offline voice dictation with Orukeet and NeMo-Speech -*- lexical-binding: t; -*-

;; Author: n0w1ht
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, multimedia
;; URL: https://github.com/n0w1ht/dictate

;;; Commentary:

;; Speak, and the words are typed where point was.  Everything runs on
;; your own computer: ffmpeg records the microphone and NeMo-Speech
;; (NVIDIA's speech runtime) turns each phrase into text with the
;; Orukeet model.  No account, no API key, no internet.
;;
;;   C-c v        start dictating; each phrase is typed when you pause;
;;                press again to stop
;;   M-x dictate-cancel              stop without transcribing
;;   M-x dictate-select-microphone   pick the microphone
;;   M-x dictate-check               show what is installed and found
;;
;; After dictating:
;;
;;   M-x dictate-correct          fix a misheard word here and from now on
;;   M-x dictate-replay           hear the phrase at point again
;;   M-x dictate-retranscribe     transcribe the phrase at point again
;;   M-x dictate-switch-language  dictate the next phrases in another language
;;
;; Unpack a NeMo-Speech release (github.com/NVIDIA/NeMo-Speech.cpp)
;; into ~/.nemo-speech/ and put orukeet-v0.1.0-f16.gguf (from
;; huggingface.co/oruk/orukeet) in ~/.nemo-speech/models/, or set
;; `dictate-program' and `dictate-model'.
;;
;; Orukeet writes capitals and punctuation itself.  Each phrase comes
;; back as a sentence of its own, so a phrase that follows a short pause
;; is joined to the one before it; see `dictate-sentence-pause'.  You can
;; still say "period", "comma", "new line", "new paragraph", "delete
;; that" and "stop dictating"; see `dictate-commands'.  Set
;; `dictate-punctuation' to `spoken' to have only the punctuation you say.
;;
;; Set `dictate-live' to nil to have everything typed at once after you
;; stop instead.
;;
;; Works in any buffer you can type in, including the minibuffer.  In a
;; read-only buffer (a PDF, the readq dashboard) the text goes to the kill
;; ring instead, ready for C-y.
;;
;; The microphone is read through PulseAudio on GNU/Linux, DirectShow on
;; Windows and AVFoundation on macOS.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

;;;; Options

(defgroup dictate nil
  "Offline voice dictation with Orukeet and NeMo-Speech."
  :group 'convenience
  :prefix "dictate-")

;;;;; Speech recognition

(defcustom dictate-nemo-directory "~/.nemo-speech/"
  "Folder searched for nemo-speech, and its models/ folder for a model.
Used when `dictate-program' or `dictate-model' is nil."
  :type 'directory)

(defcustom dictate-program nil
  "The NeMo-Speech command line program (nemo-speech).
When nil, look for nemo-speech on PATH, then under
`dictate-nemo-directory', taking the newest release found."
  :type '(choice (const :tag "Find automatically" nil) file))

(defcustom dictate-model nil
  "The speech model file (*.gguf) for NeMo-Speech.
When nil, use the newest .gguf file in the models/ folder of
`dictate-nemo-directory'."
  :type '(choice (const :tag "Find automatically" nil) file))

(defcustom dictate-language "en"
  "Language you dictate in, as a code such as \"en\" or \"de\".
Orukeet knows 25 European languages and can guess which one is spoken,
but guesses badly on short phrases; nil lets it guess."
  :type '(choice (const :tag "Detect" nil) string))

(defcustom dictate-punctuation 'model
  "Who punctuates the text.
`model': the model writes capitals and punctuation; you can still say
\"period\" or \"comma\".  `spoken': the model writes lower case without
punctuation, and only the punctuation you say is typed."
  :type '(choice (const :tag "The model" model)
                 (const :tag "Only what I say" spoken)))

(defcustom dictate-vocabulary nil
  "Words and phrases the recognizer should favour.
Drug names, eponyms, abbreviations: anything it keeps getting wrong.
Each is passed to nemo-speech as a --speech-context phrase."
  :type '(repeat string))

(defcustom dictate-device nil
  "Where NeMo-Speech runs the model: \"cpu\", \"vulkan\", \"cuda\" or \"metal\".
nil lets it choose, which uses the graphics card when it can."
  :type '(choice (const :tag "Automatic" nil) string))

(defcustom dictate-extra-args nil
  "More arguments for nemo-speech transcribe."
  :type '(repeat string))

;;;;; Recording

(defcustom dictate-ffmpeg-program "ffmpeg"
  "The ffmpeg program used to record the microphone."
  :type 'string)

(defcustom dictate-microphone nil
  "The microphone to record from.
On GNU/Linux, a PulseAudio source (nil means \"default\").  On Windows,
the DirectShow device name, as listed by `dictate-select-microphone';
nil uses the first microphone found.  On macOS, an AVFoundation audio
index (nil means \"0\")."
  :type '(choice (const :tag "Default" nil) string))

(defcustom dictate-input-args nil
  "Arguments that tell ffmpeg where to record from.
When nil, they are built from `system-type' and `dictate-microphone'.
For example (\"-f\" \"pulse\" \"-i\" \"alsa_input.usb-headset\")."
  :type '(repeat string))

(defcustom dictate-audio-filter "highpass=f=100"
  "An ffmpeg audio filter applied to the microphone, or nil for none.
The default cuts the low rumble (fans, hum, a laptop's own vibration)
below 100 Hz, which is not speech but drowns it out and keeps pauses
from being heard."
  :type '(choice (const :tag "None" nil) string))

(defcustom dictate-max-seconds 600
  "Stop recording on its own after this many seconds."
  :type 'integer)

(defcustom dictate-stop-timeout 4
  "Seconds to wait for ffmpeg to finish after asking it to stop."
  :type 'number)

(defcustom dictate-directory (locate-user-emacs-file "dictate/")
  "Folder where `dictate-keep-audio' keeps the last recording."
  :type 'directory)

(defcustom dictate-keep-audio nil
  "When non-nil, keep the last recording as last.wav in `dictate-directory'."
  :type 'boolean)

;;;;; Phrases

(defcustom dictate-live t
  "When non-nil, type each phrase as soon as you pause.
You keep talking while earlier phrases are transcribed.  When nil,
everything is transcribed in one go after you stop, which punctuates
long dictations a little better."
  :type 'boolean)

(defcustom dictate-live-pause 0.7
  "Seconds of quiet that end a phrase in live mode."
  :type 'number)

(defcustom dictate-sentence-pause 1.5
  "Pause, in seconds, that the model's full stop at the end of a phrase needs.
The model sees one phrase at a time, so it ends each with a full stop
and starts each with a capital.  When the next phrase came after a
shorter pause, the sentence is taken to go on: the full stop is taken
back and the next word is written in lower case.  nil keeps the
model's punctuation as it is."
  :type '(choice (const :tag "Never join phrases" nil) number))

(defcustom dictate-live-max-phrase 25
  "Longest phrase in live mode, in seconds.
After 80% of this, a quarter second pause is enough to end it."
  :type 'number)

(defcustom dictate-live-min-speech 0.3
  "Seconds of sound a phrase needs; shorter ones (a cough) are dropped."
  :type 'number)

(defcustom dictate-live-max-gap 5
  "Seconds of sound before a phrase that are transcribed with it.
Sound between phrases that was too quiet to count as speech is sent
with the next phrase, so soft words are not lost; this caps how much."
  :type 'number)

(defcustom dictate-live-sensitivity 3.0
  "How much louder than the background noise speech must be.
Raise it if background noise keeps phrases from ending; lower it if
quiet speech is missed."
  :type 'number)

(defcustom dictate-live-min-level 150
  "Lowest loudness (mean sample size, out of 32768) counted as speech."
  :type 'integer)

(defcustom dictate-live-show-level nil
  "When non-nil, show the loudness and the speech threshold in the mode line.
Useful for tuning `dictate-live-sensitivity' and `dictate-live-min-level'."
  :type 'boolean)

;;;;; Text

(defcustom dictate-smart-spacing t
  "When non-nil, fit the dictated text to the text around it.
A space is added before or after when needed, a new line or sentence
starts with a capital, and the first word is written in lower case
when you dictate into the middle of a sentence."
  :type 'boolean)

(defcustom dictate-commands
  '(("new line" "\n" t)
    ("new paragraph" "\n\n" t)
    ("delete that" dictate-delete-last)
    ("scratch that" dictate-delete-last)
    ("undo" dictate-delete-last)
    ("stop dictating" dictate-stop-dictating)
    ("comma" "," end)
    ("period" "." end)
    ("full stop" "." end)
    ("question mark" "?" end)
    ("exclamation mark" "!" end)
    ("colon" ":")
    ("semicolon" ";"))
  "Spoken commands, as (WORDS ACTION WHERE).
WORDS are what you say, in any case; they are also found run together
\(\"newline\") or hyphenated.  ACTION is a string to type, or a function
called with point where dictation types; it may insert text there.
A command is only taken as one when it is said on its own, between
pauses, unless WHERE says otherwise: t means it also works in the
middle of a phrase (\"stroke volume new line cardiac output\"), which
suits words you would never dictate as text; `end' means it also works
as the last words of a phrase (\"chest pain period\").

A punctuation mark typed by a command replaces one the model wrote
just before it, so \"chest pain period\" gives one full stop, not two."
  :type '(repeat (list (string :tag "Words")
                       (choice (string :tag "Type")
                               (function :tag "Call"))
                       (choice (const :tag "Only on its own" nil)
                               (const :tag "Also inside a phrase" t)
                               (const :tag "Also at the end of a phrase" end)))))

(defcustom dictate-after-insert-hook nil
  "Hook run after dictated text is inserted.
Each function gets the start and end of the inserted text, and runs in
the buffer where it was inserted."
  :type 'hook)

(defcustom dictate-text-functions nil
  "Functions that change each transcribed phrase before it is typed.
Each gets the text and returns the text to type, or nil to drop the
phrase.  They run after `dictate-corrections' and before spoken
commands are looked for, in order."
  :type 'hook)

;;;;; Corrections, replay and languages

(defcustom dictate-corrections nil
  "Words the recognizer gets wrong, as (HEARD . MEANT) pairs.
HEARD is matched as whole words in any case; MEANT keeps its own
capitals, or follows those of HEARD when it has none.  Corrections
made with \\[dictate-correct] are kept in `dictate-corrections-file'
and apply as well."
  :type '(alist :key-type (string :tag "Heard") :value-type (string :tag "Meant")))

(defcustom dictate-corrections-file
  (expand-file-name "corrections.eld" (locate-user-emacs-file "dictate/"))
  "File where \\[dictate-correct] keeps the corrections it learns."
  :type 'file)

(defcustom dictate-recent-phrases 20
  "How many recent phrases keep their audio, for \\[dictate-replay].
The audio is kept in a private temporary folder that is deleted when
Emacs exits.  0 keeps none: each recording is deleted once transcribed."
  :type 'integer)

(defcustom dictate-play-program "ffplay"
  "Program that plays a phrase's audio for \\[dictate-replay]."
  :type 'string)

(defcustom dictate-play-args '("-nodisp" "-autoexit" "-loglevel" "quiet")
  "Arguments for `dictate-play-program', before the file name."
  :type '(repeat string))

(defcustom dictate-languages '("en")
  "Languages \\[dictate-switch-language] goes through, as codes like \"fr\".
With more than one, the mode line shows the language while you dictate."
  :type '(repeat string))

(defface dictate-recording '((t :inherit error :weight bold))
  "Face of the mode line note while recording.")

(defface dictate-transcribing '((t :inherit warning))
  "Face of the mode line note while transcribing.")

;;;; State

(cl-defstruct (dictate--session (:constructor dictate--session-create))
  "One dictation: a recording and the transcription of its phrases."
  process           ; ffmpeg
  marker            ; where the next text goes
  live              ; non-nil to type phrase by phrase
  stopping cancelled done
  ;; Audio
  (pending "")      ; bytes that do not yet fill a frame
  chunks            ; one-shot mode: everything recorded, newest first
  ;; Pause detection, in live mode
  frames            ; frames of the current phrase, newest first
  (count 0)         ; frames in the current phrase
  (speech 0)        ; frames in the current phrase that were loud enough
  (silence 0)       ; quiet frames since the last loud one in the phrase
  preroll           ; quiet frames before the phrase, newest first
  levels            ; levels of recent frames, newest first
  (levels-count 0)  ; length of levels
  floor             ; estimate of the background noise level
  since             ; every frame since the last phrase sent, newest first
  (since-count 0)   ; length of since
  sent              ; non-nil once a phrase was queued for transcription
  (level 0)         ; level of the last frame
  quiet             ; frames since the last loud one, across phrases
  gap               ; seconds of quiet before the current phrase
  ;; Transcription
  queue             ; phrases waiting to be transcribed, oldest first;
                    ; each a plist (:wav FILE :gap SECONDS :language CODE)
  busy              ; non-nil while nemo-speech runs
  ;; Typing
  period            ; end of the last phrase, when the model ended it with "."
  copied            ; non-nil once text went to the kill ring
  history)          ; (START . END) markers of what was typed, newest first

(defvar dictate--recording nil
  "The session that is recording, or nil.")

(defvar dictate--last-session nil
  "The most recent session, for `dictate-delete-last'.")

(defvar dictate--command-session nil
  "The session whose spoken command is being carried out.")

(defvar dictate--jobs 0
  "Number of transcriptions running.")

(defvar dictate--program-cache nil
  "Program found by `dictate--program', as (DIRECTORY . PROGRAM).")

(defvar dictate--phrases nil
  "Recent phrases, newest first, for `dictate-replay' and `dictate-retranscribe'.
Each is a plist: :wav, the audio file or nil; :language; :start and
:end, markers around the text it typed, or nil when it typed none.")

(defvar dictate--audio-directory nil
  "Private folder holding the audio of `dictate--phrases', or nil.")

;;;; Mode line

(defconst dictate--mode-line '(:eval (dictate--mode-line-string))
  "Mode line construct added to `global-mode-string'.")

(defun dictate--mode-line-string ()
  "Return the mode line note for the current state."
  (concat
   (when-let ((session dictate--recording))
     (propertize
      (concat
       (cond ((dictate--session-stopping session) " ● stopping")
             ((not (dictate--session-live session)) " ● Dictating")
             ((dictate--session-frames session) " ● Hearing you")
             (t " ● Listening"))
       (when (cdr dictate-languages)
         (format " [%s]" (or dictate-language "auto")))
       (when (and dictate-live-show-level (dictate--session-live session))
         (format " %d/%d" (dictate--session-level session)
                 (dictate--threshold session))))
      'face 'dictate-recording
      'help-echo (substitute-command-keys "\\[dictate-toggle] stops dictating")))
   (when (> dictate--jobs 0)
     (propertize " Transcribing…" 'face 'dictate-transcribing))))

(defun dictate--update-mode-line ()
  "Show or hide the mode line note."
  (if (or dictate--recording (> dictate--jobs 0))
      (progn
        (unless (listp global-mode-string)
          (setq global-mode-string (list global-mode-string)))
        (unless (member dictate--mode-line global-mode-string)
          (setq global-mode-string
                (append global-mode-string (list dictate--mode-line)))))
    (when (listp global-mode-string)
      (setq global-mode-string
            (delete dictate--mode-line global-mode-string))))
  (force-mode-line-update t))

;;;; Finding programs and models

(defun dictate--ffmpeg ()
  "Return the ffmpeg program, or signal an error."
  (or (executable-find dictate-ffmpeg-program)
      (user-error "Dictate: ffmpeg not found; install it with your package manager (on Windows: winget install Gyan.FFmpeg, then restart Emacs)")))

(defun dictate--newest-version (files)
  "Return the file in FILES whose name has the highest version number."
  (car (sort (copy-sequence files)
             (lambda (a b) (string-version-lessp b a)))))

(defun dictate--program (&optional noerror)
  "Return the nemo-speech program.
Signal an error when it cannot be found, unless NOERROR."
  (let ((dir (expand-file-name dictate-nemo-directory)))
    (or (and dictate-program
             (or (executable-find dictate-program)
                 (let ((file (expand-file-name dictate-program)))
                   (and (file-executable-p file) file))))
        (executable-find "nemo-speech")
        (and dictate--program-cache
             (equal (car dictate--program-cache) dir)
             (file-executable-p (cdr dictate--program-cache))
             (cdr dictate--program-cache))
        (when-let ((found (and (file-directory-p dir)
                               (dictate--newest-version
                                (seq-filter
                                 (lambda (f) (and (file-regular-p f)
                                                  (file-executable-p f)))
                                 (directory-files-recursively
                                  dir "\\`nemo-speech\\(?:\\.exe\\)?\\'"))))))
          (setq dictate--program-cache (cons dir found))
          found)
        (unless noerror
          (user-error "Dictate: nemo-speech not found; set `dictate-program'")))))

(defun dictate--model (&optional noerror)
  "Return the speech model file.
Signal an error when there is none, unless NOERROR."
  (or (and dictate-model (expand-file-name dictate-model))
      (let ((dir (expand-file-name "models" dictate-nemo-directory)))
        (and (file-directory-p dir)
             (car (sort (directory-files dir t "\\.gguf\\'")
                        #'file-newer-than-file-p))))
      (unless noerror
        (user-error "Dictate: no model found; set `dictate-model'"))))

;;;; Microphones

(defun dictate--parse-dshow-devices (text)
  "Return the audio devices in ffmpeg's DirectShow device list TEXT.
Each device is (NAME . ALTERNATIVE-NAME); the second may be nil."
  (let ((section nil) (devices nil) (last nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match-p "DirectShow audio devices" line)
        (setq section 'audio last nil))
       ((string-match-p "DirectShow video devices" line)
        (setq section 'video last nil))
       ((string-match "Alternative name \"\\(.*\\)\"" line)
        (when last
          (setcdr last (match-string 1 line))
          (setq last nil)))
       ((string-match "\\] +\"\\(.*\\)\"\\(?: +(\\([a-z, ]+\\))\\)?" line)
        (let ((name (match-string 1 line))
              (kind (match-string 2 line)))
          (if (if kind (string-match-p "audio" kind) (eq section 'audio))
              (push (setq last (list name)) devices)
            (setq last nil))))))
    (nreverse devices)))

(defun dictate--parse-pulse-sources (text)
  "Return the microphones in TEXT, the output of \"pactl list sources\".
Each is (DESCRIPTION . NAME); monitors of speakers are left out."
  (let ((sources nil) (name nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match "^[ \t]*Name: \\(.*\\)" line)
        (setq name (string-trim (match-string 1 line))))
       ((and name (string-match "^[ \t]*Description: \\(.*\\)" line))
        (unless (string-suffix-p ".monitor" name)
          (push (cons (string-trim (match-string 1 line)) name) sources))
        (setq name nil))))
    (nreverse sources)))

(defun dictate--call (program &rest args)
  "Run PROGRAM with ARGS and return what it printed, read as UTF-8."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8)
          (process-environment (cons "LC_ALL=C" process-environment)))
      (apply #'call-process program nil t nil args))
    (buffer-string)))

(defun dictate--list-microphones ()
  "Return the microphones that can be recorded from, as (NAME . ARGUMENT).
On GNU/Linux these are PulseAudio (or PipeWire) sources, where ARGUMENT
is the source name; on Windows DirectShow devices, where ARGUMENT is the
alternative name."
  (pcase system-type
    ('windows-nt
     (dictate--parse-dshow-devices
      (dictate--call (dictate--ffmpeg) "-hide_banner" "-list_devices" "true"
                     "-f" "dshow" "-i" "dummy")))
    ('darwin
     (user-error "Dictate: set `dictate-microphone' to an AVFoundation audio index"))
    (_
     (unless (executable-find "pactl")
       (user-error "Dictate: pactl not found; set `dictate-microphone' to a PulseAudio source"))
     (dictate--parse-pulse-sources (dictate--call "pactl" "list" "sources")))))

(defun dictate--device-argument (device)
  "Return the name to give ffmpeg for DEVICE, a (NAME . ALTERNATIVE-NAME).
Names with letters outside ASCII can be garbled on the way to ffmpeg,
so the alternative name is used for those."
  (if (or (string-match-p "\\`[[:ascii:]]*\\'" (car device))
          (null (cdr device)))
      (car device)
    (cdr device)))

;;;###autoload
(defun dictate-select-microphone ()
  "Pick the microphone to dictate with, for this session.
Use \\[customize-variable] `dictate-microphone' to keep the choice."
  (interactive)
  (let* ((devices (or (dictate--list-microphones)
                      (user-error "Dictate: no microphone found")))
         (name (completing-read "Microphone: " (mapcar #'car devices) nil t)))
    (setq dictate-microphone
          (if (eq system-type 'windows-nt)
              (dictate--device-argument (assoc name devices))
            (cdr (assoc name devices))))
    (message "Dictate: using %s (add (setq dictate-microphone %S) to your init file to keep it)"
             name dictate-microphone)))

(defun dictate--input-arguments ()
  "Return the ffmpeg arguments that select the microphone."
  (or dictate-input-args
      (pcase system-type
        ('windows-nt
         (list "-f" "dshow" "-i"
               (concat "audio="
                       (or dictate-microphone
                           (let ((device (car (dictate--list-microphones))))
                             (unless device
                               (user-error "Dictate: ffmpeg found no microphone"))
                             (dictate--device-argument device))))))
        ('darwin
         (list "-f" "avfoundation" "-i" (concat ":" (or dictate-microphone "0"))))
        (_ (list "-f" "pulse" "-i" (or dictate-microphone "default"))))))

;;;; Recording

;; ffmpeg sends the samples (16 kHz, mono, 16 bit) to Emacs through a
;; pipe.  In live mode Emacs measures how loud each 20 ms frame is, and
;; a pause after speech ends a phrase, which is transcribed while you
;; go on talking.  Otherwise everything is kept until you stop.

(defconst dictate--frame-bytes 640
  "Bytes in one 20 ms frame of 16 kHz 16 bit samples.")

(defconst dictate--frames-per-second 50
  "Frames in one second.")

(defconst dictate--noise-window 5
  "Seconds of recent sound used to estimate the background noise.")

(defconst dictate--noise-percentile 0.2
  "Fraction of recent frames assumed to be background noise or quieter.")

(defun dictate--start ()
  "Start recording at point."
  (let* ((ffmpeg (dictate--ffmpeg))
         (_ (dictate--program))
         (_ (dictate--model))
         (input (dictate--input-arguments))
         (log (get-buffer-create " *dictate-ffmpeg*"))
         (session (dictate--session-create
                   :marker (copy-marker (point)) :live dictate-live)))
    (with-current-buffer log (erase-buffer))
    (setf (dictate--session-process session)
          (make-process
           :name "dictate-record"
           :command (append (list ffmpeg "-hide_banner" "-loglevel" "error"
                                  "-nostats")
                            input
                            (list "-t" (number-to-string dictate-max-seconds)
                                  "-ac" "1" "-ar" "16000")
                            (when (and dictate-audio-filter
                                       (not (string-empty-p dictate-audio-filter)))
                              (list "-af" dictate-audio-filter))
                            (list "-f" "s16le" "-"))
           :connection-type 'pipe
           :coding 'no-conversion
           :noquery t
           :stderr log
           :filter (lambda (_process string) (dictate--receive session string))
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (dictate--recording-ended session)))))
    (setq dictate--recording session
          dictate--last-session session)
    (dictate--update-mode-line)
    (message "Dictate: speak now%s; %s stops"
             (if dictate-live ", the text comes after each pause" "")
             (substitute-command-keys "\\[dictate-toggle]"))))

(defun dictate--stop (&optional cancel)
  "Ask ffmpeg to stop recording.
With CANCEL, throw away what was not typed yet."
  (let* ((session dictate--recording)
         (process (dictate--session-process session)))
    (setf (dictate--session-stopping session) t)
    (when cancel
      (setf (dictate--session-cancelled session) t))
    (dictate--update-mode-line)
    (when (process-live-p process)
      ;; ffmpeg stops cleanly when it reads q, also from a pipe on Windows.
      (ignore-errors (process-send-string process "q"))
      (run-at-time dictate-stop-timeout nil
                   (lambda ()
                     (when (process-live-p process)
                       (delete-process process)))))))

(defun dictate--receive (session string)
  "Take the samples in STRING, sent by ffmpeg for SESSION."
  (when (multibyte-string-p string)
    (setq string (string-to-unibyte string)))
  (if (not (dictate--session-live session))
      (push string (dictate--session-chunks session))
    (let* ((data (concat (dictate--session-pending session) string))
           (n (length data))
           (i 0)
           (was-speaking (dictate--session-frames session)))
      (while (<= (+ i dictate--frame-bytes) n)
        (dictate--frame session (substring data i (+ i dictate--frame-bytes)))
        (setq i (+ i dictate--frame-bytes)))
      (setf (dictate--session-pending session) (substring data i))
      (when (or dictate-live-show-level
                (not (eq (not was-speaking)
                         (not (dictate--session-frames session)))))
        (force-mode-line-update t)))))

(defun dictate--frame-level (frame)
  "Return the mean loudness of the 16 bit samples in FRAME."
  (let ((sum 0) (i 0) (n (length frame)))
    (while (< i n)
      (let ((v (logior (aref frame i) (ash (aref frame (1+ i)) 8))))
        (setq sum (+ sum (abs (if (>= v 32768) (- v 65536) v)))))
      (setq i (+ i 2)))
    (/ sum (max 1 (/ n 2)))))

(defun dictate--threshold (session)
  "Return the level above which a frame counts as speech in SESSION."
  (max dictate-live-min-level
       (* dictate-live-sensitivity (or (dictate--session-floor session) 0))))

(defun dictate--update-floor (session level)
  "Add LEVEL to SESSION's recent levels and re-estimate the noise floor.
The floor is a low percentile of the last few seconds, not the
quietest frame, so hiss that rises and falls is not taken for speech
each time it rises."
  (let ((max (* dictate--noise-window dictate--frames-per-second))
        (count (1+ (dictate--session-levels-count session))))
    (push level (dictate--session-levels session))
    (when (> count (+ max 25))
      (setf (dictate--session-levels session)
            (seq-take (dictate--session-levels session) max))
      (setq count max))
    (setf (dictate--session-levels-count session) count)
    ;; Sorting a few hundred numbers is cheap, but there is no need to
    ;; do it for every frame once the estimate has settled.
    (when (or (< count 50) (= (% count 10) 0))
      (let ((sorted (sort (copy-sequence (dictate--session-levels session)) #'<)))
        (setf (dictate--session-floor session)
              (float (nth (floor (* dictate--noise-percentile (1- count)))
                          sorted)))))))

(defun dictate--frame (session frame)
  "Add FRAME to SESSION, ending the phrase after a long enough pause."
  (dictate--update-floor session (dictate--frame-level frame))
  (let* ((fps dictate--frames-per-second)
         (level (car (dictate--session-levels session)))
         (speech (> level (dictate--threshold session)))
         (quiet (dictate--session-quiet session)))
    (setf (dictate--session-level session) level
          (dictate--session-quiet session)
          (cond (speech 0) (quiet (1+ quiet))))
    ;; Keep everything since the last phrase, in case no pause is ever
    ;; heard; see `dictate--recording-ended'.
    (push frame (dictate--session-since session))
    (let ((max (* fps dictate-live-max-phrase)))
      (when (> (cl-incf (dictate--session-since-count session)) (+ 50 max))
        (setf (dictate--session-since session)
              (seq-take (dictate--session-since session) max)
              (dictate--session-since-count session) max)))
    (cond
     ((dictate--session-frames session)
      (push frame (dictate--session-frames session))
      (cl-incf (dictate--session-count session))
      (if speech
          (progn (cl-incf (dictate--session-speech session))
                 (setf (dictate--session-silence session) 0))
        (cl-incf (dictate--session-silence session)))
      (let ((count (dictate--session-count session))
            (silence (dictate--session-silence session))
            (max (* fps dictate-live-max-phrase)))
        ;; End the phrase after a pause; when it gets long, take a
        ;; shorter pause; and never let it grow past the maximum.
        (when (or (>= silence (* fps dictate-live-pause))
                  (and (>= count (* 0.8 max)) (>= silence (/ fps 4)))
                  (>= count max))
          (dictate--end-phrase session))))
     (speech
      ;; A phrase starts.  How long the quiet before it was tells
      ;; whether it goes on with the sentence before.
      (setf (dictate--session-gap session) (and quiet (/ quiet (float fps)))
            (dictate--session-frames session)
            (cons frame (dictate--session-preroll session))
            (dictate--session-count session)
            (1+ (length (dictate--session-preroll session)))
            (dictate--session-speech session) 1
            (dictate--session-silence session) 0
            (dictate--session-preroll session) nil))
     (t
      ;; Keep a quarter second before speech starts, so the first
      ;; sound of the first word is not cut off.
      (push frame (dictate--session-preroll session))
      (when (> (length (dictate--session-preroll session)) (/ fps 4))
        (setf (dictate--session-preroll session)
              (butlast (dictate--session-preroll session))))))))

(defun dictate--end-phrase (session)
  "Queue SESSION's current phrase for transcription, unless it was only a noise."
  (let ((frames (dictate--session-frames session))
        (speech (dictate--session-speech session)))
    (setf (dictate--session-frames session) nil
          (dictate--session-count session) 0
          (dictate--session-speech session) 0
          (dictate--session-silence session) 0)
    (when (and frames
               (>= speech (* dictate-live-min-speech dictate--frames-per-second)))
      ;; Send everything since the last phrase, not just this phrase's
      ;; frames: speech too quiet to count as speech (a soft word, or a
      ;; mic so loud that its hiss raises the bar) is then never lost.
      ;; Only a long stretch of quiet before the phrase is left out.
      (let* ((keep (min (dictate--session-since-count session)
                        (+ (length frames)
                           (* dictate-live-max-gap dictate--frames-per-second))))
             (audio (seq-take (dictate--session-since session) keep)))
        (setf (dictate--session-sent session) t
              (dictate--session-since session) nil
              (dictate--session-since-count session) 0)
        (dictate--enqueue session (apply #'concat (nreverse audio))
                          (dictate--session-gap session))))))

(defun dictate--recording-ended (session)
  "Finish SESSION after ffmpeg ended."
  (when (eq dictate--recording session)
    (setq dictate--recording nil))
  (setf (dictate--session-done session) t)
  (cond
   ((dictate--session-cancelled session)
    (setf (dictate--session-queue session) nil)
    (message "Dictate: cancelled"))
   ((dictate--session-live session)
    (dictate--end-phrase session)
    ;; Nothing was ever taken for speech (a very quiet voice, or noise
    ;; louder than speech): send what was recorded, rather than nothing.
    (unless (or (dictate--session-sent session)
                (< (dictate--session-since-count session)
                   dictate--frames-per-second))
      (setf (dictate--session-sent session) t)
      (dictate--enqueue session (apply #'concat (nreverse (dictate--session-since session))))
      (setf (dictate--session-since session) nil)))
   (t
    (let ((data (apply #'concat (nreverse (dictate--session-chunks session)))))
      (setf (dictate--session-chunks session) nil)
      (if (< (length data) 3200)          ; under a tenth of a second
          (let ((log (with-current-buffer (get-buffer-create " *dictate-ffmpeg*")
                       (string-trim (buffer-string)))))
            (message "Dictate: nothing was recorded%s"
                     (if (string-empty-p log) "" (concat ": " log))))
        (unless (dictate--session-stopping session)
          (message "Dictate: recording stopped after %d seconds"
                   dictate-max-seconds))
        (dictate--enqueue session data)))))
  (dictate--update-mode-line)
  (dictate--next session))

;;;; WAV files

(defun dictate--little-endian (value bytes)
  "Return VALUE as a unibyte string of BYTES bytes, least significant first."
  (apply #'unibyte-string
         (mapcar (lambda (i) (logand (ash value (* -8 i)) 255))
                 (number-sequence 0 (1- bytes)))))

(defun dictate--wav-header (data-bytes)
  "Return a WAV header for DATA-BYTES of 16 kHz mono 16 bit audio."
  (concat "RIFF" (dictate--little-endian (+ 36 data-bytes) 4)
          "WAVE" "fmt " (dictate--little-endian 16 4)
          (dictate--little-endian 1 2)      ; PCM
          (dictate--little-endian 1 2)      ; mono
          (dictate--little-endian 16000 4)  ; sample rate
          (dictate--little-endian 32000 4)  ; bytes per second
          (dictate--little-endian 2 2)      ; bytes per sample
          (dictate--little-endian 16 2)     ; bits per sample
          "data" (dictate--little-endian data-bytes 4)))

(defun dictate--write-wav (data wav)
  "Write the 16 kHz mono 16 bit samples in DATA as the WAV file WAV."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert data)
    (when (= (% (buffer-size) 2) 1)
      (delete-region (1- (point-max)) (point-max)))
    (goto-char (point-min))
    (insert (dictate--wav-header (buffer-size)))
    (let ((coding-system-for-write 'no-conversion))
      (write-region nil nil wav nil 'silent))))

(defun dictate--enqueue (session data &optional gap)
  "Save DATA as a WAV file and queue it for transcription in SESSION.
GAP is the seconds of quiet before it, or nil when unknown."
  (let ((wav (make-temp-file "dictate-" nil ".wav")))
    (dictate--write-wav data wav)
    (when dictate-keep-audio
      (make-directory dictate-directory t)
      (copy-file wav (expand-file-name "last.wav" dictate-directory) t))
    ;; The language is the one when the phrase was said, so switching
    ;; language while earlier phrases wait does not change them.
    (setf (dictate--session-queue session)
          (append (dictate--session-queue session)
                  (list (list :wav wav :gap gap :language dictate-language))))
    (dictate--next session)))

;;;; Transcribing

(defun dictate--arguments (wav)
  "Return the nemo-speech arguments that transcribe WAV to stdout."
  (append (list "transcribe" wav "--model" (dictate--model) "--no-warmup")
          (when dictate-language (list "--language" dictate-language))
          (when (eq dictate-punctuation 'spoken) (list "--no-punctuation"))
          (when dictate-device (list "--device" dictate-device))
          (mapcan (lambda (phrase) (list "--speech-context" phrase))
                  dictate-vocabulary)
          dictate-extra-args))

(defun dictate--next (session)
  "Transcribe the next phrase queued in SESSION, unless one is running.
Phrases are transcribed one at a time, so they are typed in order."
  (unless (dictate--session-busy session)
    (let ((item (pop (dictate--session-queue session))))
      (cond
       (item
        (setf (dictate--session-busy session) t)
        (let ((dictate-language (plist-get item :language)))
          (dictate--transcribe
           (plist-get item :wav)
           (lambda (text)
             (setf (dictate--session-busy session) nil)
             (if (dictate--session-cancelled session)
                 (ignore-errors (delete-file (plist-get item :wav)))
               (dictate--type-phrase (dictate--process-text text) session item))
             (dictate--next session)))))
       ((dictate--session-done session)
        (set-marker (dictate--session-marker session) nil))))))

(defun dictate--transcribe (wav callback)
  "Turn WAV into text and call CALLBACK with the text.
CALLBACK gets nil when nemo-speech fails.  WAV is left for the caller."
  (let ((out (generate-new-buffer " *dictate-out*"))
        (err (generate-new-buffer " *dictate-err*")))
    (cl-incf dictate--jobs)
    (dictate--update-mode-line)
    (make-process
     :name "dictate-transcribe"
     :buffer out
     :command (cons (dictate--program) (dictate--arguments wav))
     :stderr err
     :connection-type 'pipe
     :coding 'utf-8
     :noquery t
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (setq dictate--jobs (max 0 (1- dictate--jobs)))
         (dictate--update-mode-line)
         (let ((text nil))
           (unwind-protect
               ;; nemo-speech prints the text on stdout, its log on stderr.
               (if (zerop (process-exit-status process))
                   (setq text (dictate--clean (with-current-buffer out (buffer-string))))
                 (message "Dictate: nemo-speech failed: %s"
                          (dictate--tail (if (buffer-live-p err) err out))))
             (kill-buffer out)
             (when (buffer-live-p err)
               (when-let ((p (get-buffer-process err))) (delete-process p))
               (kill-buffer err)))
           (funcall callback text)))))))

(defun dictate--tail (buffer)
  "Return the last few lines of BUFFER, on one line."
  (with-current-buffer buffer
    (string-trim
     (replace-regexp-in-string
      "[ \t\n]+" " "
      (buffer-substring (max (point-min) (- (point-max) 300)) (point-max))))))

(defun dictate--clean (text)
  "Return the recognized TEXT on one line, without sound notes like [noise].
In `spoken' punctuation the pronoun i is written I."
  (let ((s (string-trim
            (replace-regexp-in-string
             "[ \t\n\r]+" " " (replace-regexp-in-string "\\[[^]\n]*\\]" " " text)))))
    (cond
     ;; Only noises in brackets: nothing was said.
     ((string-match-p "\\`\\(?:([^)]*)\\|\\*[^*]*\\*\\| \\)*\\'" s) "")
     ((eq dictate-punctuation 'spoken)
      (let ((case-fold-search nil))
        (replace-regexp-in-string "\\bi\\('\\(?:m\\|ll\\|ve\\|d\\)\\)?\\b" "I\\1" s t)))
     (t s))))

;;;; Corrections

(defvar dictate--file-corrections nil
  "Corrections read from `dictate-corrections-file', as (FILE TIME . LIST).")

(defun dictate--learned-corrections ()
  "Return the corrections kept in `dictate-corrections-file'.
The file is read again only when it changed."
  (let* ((file (expand-file-name dictate-corrections-file))
         (time (file-attribute-modification-time (file-attributes file))))
    (when time
      (unless (and (equal (car dictate--file-corrections) file)
                   (equal (cadr dictate--file-corrections) time))
        (setq dictate--file-corrections
              (cons file
                    (cons time
                          (condition-case err
                              (with-temp-buffer
                                (insert-file-contents file)
                                (read (current-buffer)))
                            (error
                             (message "Dictate: cannot read %s: %s"
                                      file (error-message-string err))
                             nil))))))
      (cddr dictate--file-corrections))))

(defun dictate--write-corrections (corrections)
  "Write CORRECTIONS, a list of (HEARD . MEANT), to `dictate-corrections-file'."
  (let ((file (expand-file-name dictate-corrections-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; Corrections learnt by M-x dictate-correct, as (HEARD . MEANT).\n")
      (let ((print-length nil) (print-level nil))
        (pp corrections (current-buffer))))
    (setq dictate--file-corrections nil)))

(defun dictate--correction-regexp (heard)
  "Return a regexp matching the words HEARD, also hyphenated."
  (concat "\\b" (mapconcat #'regexp-quote (split-string heard) "[- ]+") "\\b"))

(defun dictate--match-case (found meant)
  "Return MEANT with a capital when FOUND starts with one and MEANT has none.
An acronym such as ECG does not count: its capitals are not a sentence's."
  (let ((case-fold-search nil))
    (if (and (not (string-empty-p meant))
             (not (string-match-p "[[:upper:]]" meant))
             (string-match-p "\\`[[:upper:]]\\(?:[^[:upper:]]\\|\\'\\)" found))
        (concat (upcase (substring meant 0 1)) (substring meant 1))
      meant)))

(defun dictate--apply-corrections (text)
  "Return TEXT with `dictate-corrections' and the learnt corrections made."
  (let ((case-fold-search t))
    (dolist (c (append dictate-corrections (dictate--learned-corrections)))
      (setq text (replace-regexp-in-string
                  (dictate--correction-regexp (car c))
                  (lambda (found) (dictate--match-case found (cdr c)))
                  text t t)))
    ;; A correction to nothing ("um" . "") leaves a double space.
    (string-trim (replace-regexp-in-string "  +" " " text))))

(defun dictate--process-text (text)
  "Return TEXT corrected and passed through `dictate-text-functions'.
Return nil when TEXT is nil or a function drops it."
  (when text
    (setq text (dictate--apply-corrections text))
    (let ((functions dictate-text-functions))
      (while (and functions text (not (string-empty-p text)))
        (setq text (funcall (pop functions) text))))
    text))

;;;; Typing

(defun dictate--read-only-p (session)
  "Return non-nil when SESSION's text cannot go into its buffer."
  (let ((buffer (marker-buffer (dictate--session-marker session))))
    (or (not (buffer-live-p buffer))
        (buffer-local-value 'buffer-read-only buffer))))

(defun dictate--insert (text session &optional gap)
  "Type TEXT, one transcribed phrase, for SESSION.
Spoken commands in TEXT (see `dictate-commands') are carried out.
GAP is the seconds of quiet before the phrase, or nil.  When the
buffer cannot be changed, the text goes to the kill ring."
  (cond
   ((null text))                        ; nemo-speech failed and said so
   ((string-empty-p text)
    (unless (dictate--session-live session)
      (message "Dictate: heard nothing")))
   (t
    (let ((first t))
      (dolist (item (dictate--parse-commands text))
        (if (stringp item)
            (dictate--insert-text item session (and first gap))
          (dictate--run-command (cdr item) session))
        (setq first nil))))))

(defun dictate--type-phrase (text session item)
  "Type TEXT, the transcript of the queued ITEM, for SESSION.
Then remember the phrase, with its audio, for `dictate-replay'."
  (let* ((marker (dictate--session-marker session))
         (start (and text (not (string-empty-p text))
                     (not (dictate--read-only-p session))
                     (copy-marker marker))))
    (dictate--insert text session (plist-get item :gap))
    (dictate--remember (plist-get item :wav) (plist-get item :language)
                       start
                       (and start (marker-buffer marker) (copy-marker marker)))))

(defun dictate--copy (string session)
  "Add STRING to the kill ring entry SESSION is building."
  (if (dictate--session-copied session)
      (kill-append string nil)
    (kill-new (string-trim-left string))
    (setf (dictate--session-copied session) t))
  (message "Dictate: copied, paste with C-y: %s" (current-kill 0 t)))

(defun dictate--put (string session)
  "Insert STRING as it is at SESSION's marker, and move the marker past it.
Point, in the buffer and in its windows, follows when it was at the
marker.  The text is remembered for `dictate-delete-last'.  Return
\(START . END) of the inserted text."
  (let* ((marker (dictate--session-marker session))
         (buffer (marker-buffer marker)))
    (with-current-buffer buffer
      (let ((windows (seq-filter (lambda (w) (= (window-point w) marker))
                                 (get-buffer-window-list buffer nil t)))
            (at-point (= (point) marker))
            (start (marker-position marker)))
        (save-excursion
          (goto-char marker)
          (insert string))
        (let ((end (+ start (length string))))
          (when at-point (goto-char end))
          (dolist (w windows) (set-window-point w end))
          (set-marker marker end)
          (push (cons (copy-marker start) (copy-marker end))
                (dictate--session-history session))
          (when (> (length (dictate--session-history session)) 50)
            (setf (dictate--session-history session)
                  (seq-take (dictate--session-history session) 50)))
          (cons start end))))))

(defun dictate--ordinary-capital-p (text)
  "Return non-nil when TEXT starts with a word that is capitalized only
because it starts a sentence: not I, and not an acronym like ECG."
  (let ((case-fold-search nil))
    (and (string-match-p "\\`[[:upper:]][[:lower:]]" text)
         (not (string-match-p "\\`I\\(?:'\\|\\b\\)" text)))))

(defun dictate--lower-first (text)
  "Return TEXT with its first letter in lower case."
  (concat (downcase (substring text 0 1)) (substring text 1)))

(defun dictate--join (text session gap)
  "Join TEXT to the phrase before it in SESSION, when it goes on the sentence.
The model ended the phrase before with a full stop.  It is taken back
when TEXT starts in lower case, or when GAP, the pause between the two,
was shorter than `dictate-sentence-pause'.  Return TEXT, its first
word in lower case when joined, unless it is I or an acronym."
  (let ((marker (dictate--session-marker session))
        (case-fold-search nil))
    (if (and (dictate--session-period session)
             (= (dictate--session-period session) marker)
             (eq (char-before marker) ?.)
             (or (string-match-p "\\`[[:lower:]]" text)
                 (and gap dictate-sentence-pause
                      (< gap dictate-sentence-pause)
                      (string-match-p "\\`[[:alnum:]]" text))))
        (progn
          (save-excursion
            (goto-char marker)
            (delete-char -1))
          (if (dictate--ordinary-capital-p text) (dictate--lower-first text) text))
      text)))

(defun dictate--fit (text before after spaced &optional next)
  "Return TEXT fitted between the text before and after point.
BEFORE is the last character before point on the same line that is
not a space or tab, or nil; AFTER is the character right after point,
or nil; SPACED is non-nil when whitespace or a line start precedes point.
NEXT is the first character after point on the same line that is not a
space or tab; it defaults to AFTER."
  (let ((s text)
        (case-fold-search nil)
        (next (or next after)))
    (unless (string-empty-p s)
      ;; A new line or a new sentence starts with a capital.
      (when (and (or (null before) (memq before '(?. ?? ?!)))
                 (string-match-p "\\`[[:lower:]]" s))
        (setq s (concat (upcase (substring s 0 1)) (substring s 1))))
      ;; Mid-sentence: lower case the first word, unless it is I or an acronym.
      (when (and before (string-match-p "[[:alnum:],;]" (string before))
                 (dictate--ordinary-capital-p s))
        (setq s (dictate--lower-first s))))
    ;; Text going into the middle of a sentence does not end it.
    (when (and next (string-match-p "[[:lower:][:digit:]]" (string next))
               (string-suffix-p "." s))
      (setq s (substring s 0 -1)))
    (when (and before (not spaced)
               (not (memq before '(?\( ?\[ ?\{ ?\" ?' ?“ ?‘ ?/))))
      (setq s (concat " " s)))
    (when (and after (not (memq after '(?\s ?\t ?\n ?. ?, ?\; ?: ?! ?? ?\) ?\] ?\} ?\" ?' ?” ?’))))
      (setq s (concat s " ")))
    s))

(defun dictate--context (pos)
  "Return (BEFORE AFTER SPACED NEXT) for inserting at POS in the buffer.
See `dictate--fit'."
  (save-excursion
    (goto-char pos)
    (let* ((after (char-after pos))
           (next (save-excursion
                   (skip-chars-forward " \t")
                   (and (not (eolp)) (char-after))))
           (spaced (and (char-before pos)
                        (memq (char-before pos) '(?\s ?\t ?\n))))
           (before (progn (skip-chars-backward " \t")
                          (and (not (bolp)) (char-before)))))
      (list before after (or spaced (and (null before) t)) next))))

(defun dictate--insert-text (text session &optional gap)
  "Type the dictated TEXT at SESSION's marker, fitted to its surroundings.
GAP is the seconds of quiet before it; see `dictate--join'."
  (if (dictate--read-only-p session)
      (dictate--copy (if (and (dictate--session-copied session)
                              (string-suffix-p "\n" (current-kill 0 t)))
                         text
                       (concat " " text))
                     session)
    (let ((marker (dictate--session-marker session)))
      (with-current-buffer (marker-buffer marker)
        (let* ((joined (dictate--join text session gap))
               (s (if dictate-smart-spacing
                      (apply #'dictate--fit joined (dictate--context marker))
                    joined))
               (region (dictate--put s session)))
          (setf (dictate--session-period session)
                (and (eq (char-before (cdr region)) ?.) (cdr region)))
          (run-hook-with-args 'dictate-after-insert-hook (car region) (cdr region))
          (unless (dictate--session-live session)
            (message "Dictate: %s" (string-trim s))))))))

;;;; Spoken commands

(defun dictate--command-regexp (words)
  "Return a regexp matching the spoken WORDS.
The words may also be run together or joined by a hyphen (newline,
new-line)."
  (concat "\\b" (mapconcat #'regexp-quote (split-string words) "[- ]?") "\\b"))

(defun dictate--parse-commands (text)
  "Split TEXT into strings to type and (command . ACTION) items.
A phrase that is nothing but a command is that command.  Commands
marked to work anywhere are also found inside phrases, and those
marked `end' as its last words."
  (let* ((case-fold-search t)
         (whole (seq-find
                 (lambda (c)
                   (string-match-p
                    (concat "\\`[[:space:][:punct:]]*"
                            (dictate--command-regexp (car c))
                            "[[:space:][:punct:]]*\\'")
                    text))
                 dictate-commands)))
    (if whole
        (list (cons 'command (nth 1 whole)))
      (let ((items nil) (pos 0) (done nil))
        (while (not done)
          (let ((best nil) (best-start nil) (best-end nil))
            (dolist (c dictate-commands)
              (when (and (eq (nth 2 c) t)
                         (string-match
                          (concat "[,;]?[ \t]*" (dictate--command-regexp (car c))
                                  "[.,!?;:]*[ \t]*")
                          text pos)
                         (or (null best-start) (< (match-beginning 0) best-start)))
                (setq best c
                      best-start (match-beginning 0)
                      best-end (match-end 0))))
            (if (not best)
                (setq done t)
              (setq items (dictate--split-end
                           (string-trim (substring text pos best-start)) items))
              (push (cons 'command (nth 1 best)) items)
              (setq pos best-end))))
        (setq items (dictate--split-end (string-trim (substring text pos)) items))
        (nreverse items)))))

(defun dictate--split-end (text items)
  "Push TEXT onto ITEMS, splitting off a command it ends with.
Only commands marked `end' in `dictate-commands' are looked for.
Return the new ITEMS, newest first."
  (let* ((case-fold-search t)
         (start nil)
         (end (seq-find
               (lambda (c)
                 (and (eq (nth 2 c) 'end)
                      (string-match
                       (concat "[ \t,;]+" (dictate--command-regexp (car c))
                               "[.,!?;:]*\\'")
                       text)
                      (setq start (match-beginning 0))))
               dictate-commands)))
    (when end
      (setq text (string-trim (substring text 0 start))))
    (unless (string-empty-p text) (push text items))
    (when end (push (cons 'command (nth 1 end)) items))
    items))

(defun dictate--punctuation-p (string)
  "Return non-nil when STRING is a single punctuation mark."
  (string-match-p "\\`[.,;:!?]\\'" string))

(defun dictate--run-command (action session)
  "Carry out the spoken command ACTION for SESSION.
A string is typed as it is.  A punctuation mark goes right after the
last word, replacing a mark dictation typed there.  A function is
called with point where dictation types."
  (cond
   ((stringp action)
    (if (dictate--read-only-p session)
        (progn
          (when (and (dictate--punctuation-p action)
                     (dictate--session-copied session))
            (let ((last (current-kill 0 t)))
              (when (string-match "[.,;:!?]?[ \t]*\\'" last)
                (kill-new (substring last 0 (match-beginning 0)) t))))
          (dictate--copy action session))
      (let ((marker (dictate--session-marker session)))
        (with-current-buffer (marker-buffer marker)
          (unless (string-prefix-p "\n" action)
            (save-excursion
              (goto-char marker)
              (let ((end (point)))
                (skip-chars-backward " \t")
                (when (and (dictate--punctuation-p action)
                           (memq (char-before) '(?. ?, ?\; ?: ?! ??))
                           (dictate--typed-p session (1- (point))))
                  (backward-char))
                (delete-region (point) end))))
          (dictate--put action session)
          (setf (dictate--session-period session) nil)))))
   ((functionp action)
    (let ((dictate--command-session session)
          (marker (dictate--session-marker session)))
      (if (dictate--read-only-p session)
          (funcall action)
        (with-current-buffer (marker-buffer marker)
          (let ((at-point (= (point) marker)))
            (save-excursion
              (goto-char marker)
              (funcall action)
              (when (marker-buffer marker)
                (set-marker marker (point))))
            (when (and at-point (marker-buffer marker))
              (goto-char marker)))))))))

(defun dictate--typed-p (session pos)
  "Return non-nil when the character at POS was typed by SESSION."
  (seq-some (lambda (r) (and (<= (car r) pos) (< pos (cdr r))))
            (dictate--session-history session)))

(defun dictate-delete-last ()
  "Delete the last phrase or command typed by dictation.
Say \"delete that\" while dictating, or run it as a command; each call
goes one phrase further back."
  (interactive)
  (let* ((session (or dictate--command-session dictate--last-session))
         (last (and session (pop (dictate--session-history session)))))
    (if (not (and last (marker-buffer (car last))))
        (message "Dictate: nothing to delete")
      (with-current-buffer (marker-buffer (car last))
        (if buffer-read-only
            (message "Dictate: the buffer is read-only")
          (delete-region (car last) (cdr last))
          (setf (dictate--session-period session) nil)
          (message "Dictate: deleted")))
      (set-marker (car last) nil)
      (set-marker (cdr last) nil))))

(defun dictate-stop-dictating ()
  "Stop dictating, as the spoken command \"stop dictating\" does."
  (interactive)
  (when (and dictate--recording
             (not (dictate--session-stopping dictate--recording)))
    (dictate--stop)))

;;;; Recent phrases: replay, transcribe again, correct

(defun dictate--audio-directory ()
  "Return the private folder for recent phrases' audio, making it if needed."
  (unless (and dictate--audio-directory (file-directory-p dictate--audio-directory))
    ;; make-temp-file makes the folder readable by its owner only.
    (setq dictate--audio-directory (make-temp-file "dictate-audio-" t)))
  dictate--audio-directory)

(defun dictate--delete-audio ()
  "Delete the audio of all recent phrases."
  (when (and dictate--audio-directory (file-directory-p dictate--audio-directory))
    (delete-directory dictate--audio-directory t))
  (setq dictate--audio-directory nil)
  (dolist (phrase dictate--phrases)
    (plist-put phrase :wav nil)))

(add-hook 'kill-emacs-hook #'dictate--delete-audio)

(defun dictate--forget (phrase)
  "Delete PHRASE's audio and markers."
  (when-let ((wav (plist-get phrase :wav))) (ignore-errors (delete-file wav)))
  (dolist (key '(:start :end))
    (when-let ((m (plist-get phrase key))) (set-marker m nil))))

(defun dictate--remember (wav language start end)
  "Remember a phrase: its audio WAV, its LANGUAGE, and its text from START to END.
Keep `dictate-recent-phrases' phrases; delete the audio of older ones.
START and END are markers, or nil when no text was typed."
  (if (not (and wav (> dictate-recent-phrases 0)))
      (when wav (ignore-errors (delete-file wav)))
    (let ((kept (expand-file-name (file-name-nondirectory wav)
                                  (dictate--audio-directory))))
      (rename-file wav kept t)
      (push (list :wav kept :language language :start start :end end)
            dictate--phrases)
      (when (> (length dictate--phrases) dictate-recent-phrases)
        (mapc #'dictate--forget (nthcdr dictate-recent-phrases dictate--phrases))
        (setq dictate--phrases (seq-take dictate--phrases dictate-recent-phrases))))))

(defun dictate--phrase-at (pos)
  "Return the recent phrase whose text in the current buffer holds POS."
  (seq-find (lambda (phrase)
              (let ((start (plist-get phrase :start))
                    (end (plist-get phrase :end)))
                (and start end
                     (eq (marker-buffer start) (current-buffer))
                     (< start end)
                     (<= start pos) (<= pos end))))
            dictate--phrases))

(defun dictate--phrase ()
  "Return the dictated phrase at point, or else the last one."
  (or (dictate--phrase-at (point))
      (car dictate--phrases)
      (user-error (if (> dictate-recent-phrases 0)
                      "Dictate: nothing dictated yet"
                    "Dictate: no phrases are kept; see `dictate-recent-phrases'"))))

(defun dictate--phrase-audio (phrase)
  "Return PHRASE's audio file, or signal an error when it is gone."
  (let ((wav (plist-get phrase :wav)))
    (unless (and wav (file-exists-p wav))
      (user-error "Dictate: the audio of that phrase is no longer kept"))
    wav))

(defun dictate--show-phrase (phrase)
  "Briefly highlight PHRASE's text, when it is in the current buffer."
  (let ((start (plist-get phrase :start))
        (end (plist-get phrase :end)))
    (when (and start (eq (marker-buffer start) (current-buffer)) (< start end))
      (require 'pulse)
      (pulse-momentary-highlight-region start end))))

(defvar dictate--player nil
  "The process playing a phrase, or nil.")

;;;###autoload
(defun dictate-replay ()
  "Play the audio of the dictated phrase at point, or of the last phrase.
Run it again while it plays to stop."
  (interactive)
  (if (process-live-p dictate--player)
      (progn (delete-process dictate--player)
             (setq dictate--player nil))
    (let* ((phrase (dictate--phrase))
           (wav (dictate--phrase-audio phrase))
           (player (or (executable-find dictate-play-program)
                       (user-error "Dictate: %s not found; set `dictate-play-program'"
                                   dictate-play-program))))
      (dictate--show-phrase phrase)
      (setq dictate--player
            (make-process :name "dictate-play"
                          :command (append (list player) dictate-play-args (list wav))
                          :connection-type 'pipe
                          :noquery t)))))

(defun dictate--read-language (prompt)
  "Ask for a language code with PROMPT; an empty answer means detect it."
  (let ((code (completing-read prompt (cons "auto" dictate-languages))))
    (unless (member code '("" "auto")) code)))

;;;###autoload
(defun dictate-retranscribe (&optional ask)
  "Transcribe the dictated phrase at point, or the last one, again.
Its text is replaced.  Use it after adding to `dictate-vocabulary' or
`dictate-corrections'.  With a prefix argument ASK, ask which language
the phrase was in; otherwise the language it was dictated in is used."
  (interactive "P")
  (let* ((phrase (dictate--phrase))
         (wav (dictate--phrase-audio phrase))
         (start (plist-get phrase :start))
         (language (if ask
                       (dictate--read-language "Language of the phrase: ")
                     (plist-get phrase :language))))
    (unless (and start (marker-buffer start))
      (user-error "Dictate: that phrase typed nothing that can be replaced"))
    (when (buffer-local-value 'buffer-read-only (marker-buffer start))
      (user-error "Dictate: the buffer is read-only"))
    (dictate--show-phrase phrase)
    (let ((dictate-language language))
      (dictate--transcribe
       wav
       (lambda (text)
         (when-let ((text (dictate--process-text text)))
           (plist-put phrase :language language)
           (dictate--replace-phrase phrase text)))))))

(defun dictate--replace-phrase (phrase text)
  "Replace the text PHRASE typed with TEXT, fitted to its surroundings."
  (let ((start (plist-get phrase :start))
        (end (plist-get phrase :end)))
    (when (marker-buffer start)
      (with-current-buffer (marker-buffer start)
        (let ((session (dictate--session-create :marker (copy-marker start) :live t)))
          (save-excursion (delete-region start end))
          (dictate--insert text session)
          (set-marker end (dictate--session-marker session))
          (set-marker (dictate--session-marker session) nil)
          (message "Dictate: %s" (buffer-substring-no-properties start end)))))))

(defun dictate--correction-bounds ()
  "Return (START . END) of the region, or of the word at point, or nil."
  (if (use-region-p)
      (cons (region-beginning) (region-end))
    (bounds-of-thing-at-point 'word)))

;;;###autoload
(defun dictate-correct (heard meant)
  "Replace HEARD with MEANT here, and in everything dictated from now on.
HEARD defaults to the region, or the word at point, which is replaced
right away.  The correction is kept in `dictate-corrections-file'.
MEANT may be empty, to drop a word such as \"um\"."
  (interactive
   (let* ((bounds (dictate--correction-bounds))
          (here (and bounds (buffer-substring-no-properties (car bounds) (cdr bounds))))
          (heard (string-trim
                  (read-string (if here (format "Correct (default %s): " here) "Correct: ")
                               nil nil here))))
     (when (string-empty-p heard) (user-error "Dictate: nothing to correct"))
     (list heard (string-trim (read-string (format "Replace \"%s\" with: " heard))))))
  (let ((bounds (dictate--correction-bounds))
        (case-fold-search t))
    (when (and bounds (not buffer-read-only)
               (string-match-p (concat "\\`" (dictate--correction-regexp heard) "\\'")
                               (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (let ((found (buffer-substring-no-properties (car bounds) (cdr bounds))))
        (save-excursion
          (goto-char (car bounds))
          (delete-region (car bounds) (cdr bounds))
          (insert (dictate--match-case found meant))
          (when (string-empty-p meant)
            (delete-horizontal-space)
            (unless (or (bolp) (eolp) (memq (char-after) '(?. ?, ?\; ?: ?! ??)))
              (insert " ")))))))
  (let ((corrections (seq-remove (lambda (c) (eq t (compare-strings (car c) nil nil
                                                                     heard nil nil t)))
                                 (dictate--learned-corrections))))
    (dictate--write-corrections (append corrections (list (cons heard meant)))))
  (message "Dictate: \"%s\" will be written \"%s\" from now on" heard meant))

;;;###autoload
(defun dictate-switch-language (&optional language)
  "Dictate in LANGUAGE, or else in the next one of `dictate-languages'.
LANGUAGE \"auto\" lets the model detect it.  Interactively, with a
prefix argument or when `dictate-languages' has only one, ask.
It applies from the next phrase on, also while dictating, so it can be
a spoken command: (\"switch language\" dictate-switch-language)."
  (interactive
   (list (when (or current-prefix-arg (null (cdr dictate-languages)))
           (or (dictate--read-language "Dictate in: ") "auto"))))
  (setq dictate-language
        (cond ((null language)
               (or (cadr (member dictate-language dictate-languages))
                   (car dictate-languages)))
              ((equal language "auto") nil)
              (t language)))
  (setq language dictate-language)
  (dictate--update-mode-line)
  (message "Dictate: now in %s" (or language "any language (detected)")))

;;;; Commands

;;;###autoload
(defun dictate-toggle ()
  "Start dictating at point, or stop and type what was said.
When `dictate-live' is non-nil, each phrase is typed after you pause."
  (interactive)
  (if dictate--recording
      (if (dictate--session-stopping dictate--recording)
          (message "Dictate: still stopping, one moment")
        (dictate--stop))
    (when (and buffer-read-only (not (minibufferp)))
      (message "Dictate: this buffer is read-only, the text will go to the kill ring"))
    (dictate--start)))

;;;###autoload
(defun dictate-cancel ()
  "Stop recording, and throw away what was not typed yet."
  (interactive)
  (if dictate--recording
      (dictate--stop t)
    (message "Dictate: not recording")))

;;;###autoload
(defun dictate-check ()
  "Show what dictation will use, and what is missing."
  (interactive)
  (let* ((ffmpeg (executable-find dictate-ffmpeg-program))
         (program (dictate--program t))
         (version (and program
                       (ignore-errors
                         (string-trim (car (split-string
                                            (dictate--call program "--version")
                                            "\n"))))))
         (model (dictate--model t))
         (mics (and ffmpeg (ignore-errors (dictate--list-microphones))))
         (ok (lambda (v) (if v "OK " "-- "))))
    (with-current-buffer (get-buffer-create "*dictate-check*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Dictation setup\n\n")
        (insert (funcall ok ffmpeg) "ffmpeg: "
                (or ffmpeg "not found; install it with your package manager") "\n")
        (insert (funcall ok program) "nemo-speech: "
                (if program
                    (concat program (if version (format " (%s)" version) ""))
                  "not found; set dictate-program")
                "\n")
        (insert (funcall ok model) "model: "
                (if model
                    (format "%s (%d MB)" model
                            (/ (or (file-attribute-size (file-attributes model)) 0)
                               1048576))
                  "none; set dictate-model")
                "\n")
        (insert (funcall ok mics) "microphones: "
                (if mics (mapconcat #'car mics ", ") "none found") "\n")
        (insert "    using: " (or dictate-microphone
                                  (and (eq system-type 'windows-nt) mics
                                       (concat (caar mics) " (first found)"))
                                  "the default")
                "\n")
        (let ((player (executable-find dictate-play-program)))
          (insert (funcall ok player) "replay: "
                  (cond ((<= dictate-recent-phrases 0) "off (dictate-recent-phrases is 0)")
                        (player (format "%s, the last %d phrases"
                                        player dictate-recent-phrases))
                        (t (format "%s not found; set dictate-play-program"
                                   dictate-play-program)))
                  "\n"))
        (insert (format "   corrections: %d in dictate-corrections, %d learnt in %s\n\n"
                        (length dictate-corrections)
                        (length (dictate--learned-corrections))
                        (abbreviate-file-name
                         (expand-file-name dictate-corrections-file))))
        (insert (format "Language: %s.  " (or dictate-language "detected")))
        (insert (if (eq dictate-punctuation 'spoken)
                    "Say \"period\" or \"comma\" at the end of a phrase.\n"
                    "The model punctuates; pause longer between sentences.\n"))
        (insert "Press " (substitute-command-keys "\\[dictate-toggle]")
                " to start dictating and again to stop.\n")
        (special-mode))
      (display-buffer (current-buffer)))))

(provide 'dictate)
;;; dictate.el ends here
