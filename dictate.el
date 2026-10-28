;;; dictate.el --- Offline voice dictation with whisper.cpp -*- lexical-binding: t; -*-

;; Author: n0w1ht
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, multimedia
;; URL: https://github.com/n0w1ht/dictate

;;; Commentary:

;; Speak, and the words are typed where point was.  Everything runs on
;; your own computer: ffmpeg records the microphone and whisper.cpp turns
;; the recording into text.  No account, no API key, no internet once the
;; model is downloaded.
;;
;;   C-c v        start dictating; each phrase is typed when you pause;
;;                press again to stop
;;   C-u C-c v    the same, but ask for the spoken language first
;;   M-x dictate-cancel              stop without transcribing
;;   M-x dictate-setup               download whisper.cpp and a model
;;   M-x dictate-select-microphone   pick the microphone (Windows)
;;   M-x dictate-check               show what is installed and found
;;
;; Set `dictate-live' to nil to have everything typed at once after you
;; stop instead.
;;
;; Works in any buffer you can type in, including the minibuffer.  In a
;; read-only buffer (a PDF, the readq dashboard) the text goes to the kill
;; ring instead, ready for C-y.
;;
;; On Windows the microphone is read through DirectShow, so no terminal
;; or PTY is needed.  On GNU/Linux PulseAudio is used, on macOS
;; AVFoundation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defgroup dictate nil
  "Offline voice dictation with whisper.cpp."
  :group 'convenience
  :prefix "dictate-")

(defcustom dictate-directory (locate-user-emacs-file "dictate/")
  "Folder where `dictate-setup' puts whisper.cpp and the models."
  :type 'directory)

(defcustom dictate-whisper-program nil
  "The whisper.cpp command line program (whisper-cli).
When nil, look for whisper-cli on PATH, then under `dictate-directory'."
  :type '(choice (const :tag "Find automatically" nil) file))

(defcustom dictate-model nil
  "The whisper.cpp model file (ggml-*.bin).
When nil, use the newest ggml-*.bin in the models folder of
`dictate-directory'."
  :type '(choice (const :tag "Find automatically" nil) file))

(defcustom dictate-ffmpeg-program "ffmpeg"
  "The ffmpeg program used to record the microphone."
  :type 'string)

(defcustom dictate-curl-program "curl"
  "The curl program used by `dictate-setup' to download files.
Windows 10 and later ship one as curl.exe."
  :type 'string)

(defcustom dictate-tar-program "tar"
  "The tar program used by `dictate-setup' to unpack the whisper.cpp zip.
The tar.exe that comes with Windows can unpack zip files."
  :type 'string)

(defcustom dictate-microphone nil
  "The microphone to record from.
On Windows, the DirectShow device name, as listed by
`dictate-select-microphone'; nil uses the first microphone found.
On GNU/Linux, a PulseAudio source (nil means \"default\").  On macOS,
an AVFoundation audio index (nil means \"0\")."
  :type '(choice (const :tag "Default" nil) string))

(defcustom dictate-input-args nil
  "Arguments that tell ffmpeg where to record from.
When nil, they are built from `system-type' and `dictate-microphone'.
For example (\"-f\" \"dshow\" \"-i\" \"audio=Microphone Array\")."
  :type '(repeat string))

(defcustom dictate-language "en"
  "Spoken language, as a two letter code, or \"auto\" to detect it.
Models whose name ends in .en understand English only."
  :type 'string)

(defcustom dictate-prompt nil
  "Text that hints whisper about vocabulary and style, or nil.
Whisper treats it as the text that came before the dictation, so a
list of words you often say helps it spell them.  For example:
\"Physiology notes. Tachycardia, myocardial infarction, glomerular
filtration rate, ACE inhibitors.\""
  :type '(choice (const :tag "None" nil) string))

(defcustom dictate-threads
  (max 1 (min 8 (if (fboundp 'num-processors) (num-processors) 4)))
  "Number of CPU threads whisper.cpp uses."
  :type 'integer)

(defcustom dictate-max-seconds 600
  "Stop recording on its own after this many seconds."
  :type 'integer)

(defcustom dictate-smart-spacing t
  "When non-nil, fit the dictated text to the text around it.
A space is added before or after when needed, and the first letter is
made lower case when you dictate into the middle of a sentence."
  :type 'boolean)

(defcustom dictate-live t
  "When non-nil, type each phrase as soon as you pause.
You keep talking while earlier phrases are transcribed.  When nil,
everything is transcribed in one go after you stop, which is a little
more accurate for long dictations."
  :type 'boolean)

(defcustom dictate-live-pause 0.7
  "Seconds of quiet that end a phrase in live mode."
  :type 'number)

(defcustom dictate-live-max-phrase 25
  "Longest phrase in live mode, in seconds.
After 80% of this, a quarter second pause is enough to end it."
  :type 'number)

(defcustom dictate-live-min-speech 0.3
  "Seconds of sound a phrase needs; shorter ones (a cough) are dropped."
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

(defcustom dictate-extra-args '("-sns")
  "Extra arguments for whisper-cli.
The default -sns stops whisper writing sounds such as (music)."
  :type '(repeat string))

(defcustom dictate-stop-timeout 4
  "Seconds to wait for ffmpeg to finish after asking it to stop."
  :type 'number)

(defcustom dictate-keep-audio nil
  "When non-nil, keep the last recording as last.wav in `dictate-directory'."
  :type 'boolean)

(defcustom dictate-whisper-url
  "https://github.com/ggml-org/whisper.cpp/releases/latest/download/whisper-bin-x64.zip"
  "Where `dictate-setup' downloads whisper.cpp for Windows."
  :type 'string)

(defcustom dictate-model-url-format
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-%s.bin"
  "Where `dictate-setup' downloads models; %s is the model name."
  :type 'string)

(defcustom dictate-after-insert-hook nil
  "Hook run after dictated text is inserted.
Each function gets the start and end of the inserted text, and runs in
the buffer where it was inserted."
  :type 'hook)

(defface dictate-recording '((t :inherit error :weight bold))
  "Face of the mode line note while recording.")

(defface dictate-transcribing '((t :inherit warning))
  "Face of the mode line note while transcribing.")

(defconst dictate-models
  '(("tiny.en" . "75 MB, fastest, English, makes more mistakes")
    ("base.en" . "142 MB, fast, English")
    ("small.en" . "466 MB, English, good with medical words (recommended)")
    ("medium.en" . "1.5 GB, English, slow on a laptop CPU")
    ("large-v3-turbo-q5_0" . "547 MB, many languages, accurate, slower")
    ("base" . "142 MB, many languages, fast")
    ("small" . "466 MB, many languages"))
  "Models offered by `dictate-setup', with a short description.")

;;;; State

(defvar dictate--recording nil
  "The `dictate--session' that is recording, or nil.")

(defvar dictate--jobs 0
  "Number of whisper processes running.")

(defvar dictate--whisper-cache nil
  "Whisper program found by `dictate--whisper', as (DIRECTORY . PROGRAM).")

(defconst dictate--mode-line '(:eval (dictate--mode-line-string))
  "Mode line construct added to `global-mode-string'.")

(defun dictate--mode-line-string ()
  "Return the mode line note for the current state."
  (concat
   (when dictate--recording
     (let ((session dictate--recording))
       (propertize
        (concat
         (cond ((dictate--session-stopping session) " ● stopping")
               ((not (dictate--session-live session)) " ● Dictating")
               ((dictate--session-frames session) " ● Hearing you")
               (t " ● Listening"))
         (when (and dictate-live-show-level (dictate--session-live session))
           (format " %d/%d" (dictate--session-level session)
                   (dictate--threshold session))))
        'face 'dictate-recording
        'help-echo "C-c v stops dictating")))
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

;;;; Finding programs and files

(defun dictate--ffmpeg ()
  "Return the ffmpeg program, or signal an error."
  (or (executable-find dictate-ffmpeg-program)
      (user-error "Dictate: ffmpeg not found; on Windows run: winget install Gyan.FFmpeg, then restart Emacs")))

(defun dictate--whisper (&optional noerror)
  "Return the whisper-cli program.
Signal an error when it cannot be found, unless NOERROR."
  (or (and dictate-whisper-program
           (or (executable-find dictate-whisper-program)
               (and (file-executable-p dictate-whisper-program)
                    dictate-whisper-program)))
      (executable-find "whisper-cli")
      (and dictate--whisper-cache
           (equal (car dictate--whisper-cache) dictate-directory)
           (file-exists-p (cdr dictate--whisper-cache))
           (cdr dictate--whisper-cache))
      (let ((found (and (file-directory-p dictate-directory)
                        (car (directory-files-recursively
                              dictate-directory
                              "\\`whisper-cli\\(\\.exe\\)?\\'")))))
        (when found
          (setq dictate--whisper-cache (cons dictate-directory found))
          found))
      (unless noerror
        (user-error "Dictate: whisper-cli not found; run M-x dictate-setup"))))

(defun dictate--models-directory ()
  "Return the folder that holds downloaded models."
  (expand-file-name "models" dictate-directory))

(defun dictate--model (&optional noerror)
  "Return the model file.
Signal an error when there is none, unless NOERROR."
  (or (and dictate-model (expand-file-name dictate-model))
      (let* ((dir (dictate--models-directory))
             (files (and (file-directory-p dir)
                         (directory-files dir t "\\`ggml-.*\\.bin\\'"))))
        (car (sort files #'file-newer-than-file-p)))
      (unless noerror
        (user-error "Dictate: no model found; run M-x dictate-setup"))))

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
              (progn (setq last (list name))
                     (push last devices))
            (setq last nil))))))
    (nreverse devices)))

(defun dictate--list-microphones ()
  "Return the microphones ffmpeg can see, as (NAME . ALTERNATIVE-NAME)."
  (unless (eq system-type 'windows-nt)
    (user-error "Dictate: listing microphones is only done on Windows; set `dictate-microphone'"))
  (dictate--parse-dshow-devices
   (with-temp-buffer
     (let ((coding-system-for-read 'utf-8))
       (call-process (dictate--ffmpeg) nil t nil "-hide_banner"
                     "-list_devices" "true" "-f" "dshow" "-i" "dummy"))
     (buffer-string))))

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
                      (user-error "Dictate: ffmpeg found no microphone")))
         (name (completing-read "Microphone: " (mapcar #'car devices) nil t)))
    (setq dictate-microphone
          (dictate--device-argument (assoc name devices)))
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

(cl-defstruct (dictate--session (:constructor dictate--session-create))
  "One dictation: a recording and the transcription of its phrases."
  process marker language live
  stopping cancelled done
  (pending "")      ; bytes that do not yet fill a frame
  chunks            ; one-shot mode: everything recorded, newest first
  frames            ; live mode: frames of the current phrase, newest first
  (count 0)         ; frames in the current phrase
  (speech 0)        ; frames in the current phrase that were loud enough
  (silence 0)       ; quiet frames since the last loud one
  preroll           ; quiet frames before the phrase, newest first
  floor             ; estimate of the background noise level
  (level 0)         ; level of the last frame
  queue             ; WAV files waiting to be transcribed, oldest first
  busy              ; non-nil while whisper runs
  last-text         ; text of the last phrase, a hint for the next one
  period            ; position of the full stop ending the last phrase
  copied)           ; non-nil once text went to the kill ring

(defun dictate--temp-file (suffix)
  "Return a new temporary file name ending in SUFFIX."
  (make-temp-file "dictate-" nil suffix))

(defun dictate--start (language)
  "Start recording; the text will be in LANGUAGE."
  (let* ((ffmpeg (dictate--ffmpeg))
         (_ (dictate--whisper))
         (_ (dictate--model))
         (input (dictate--input-arguments))
         (log (get-buffer-create " *dictate-ffmpeg*"))
         (session (dictate--session-create
                   :marker (copy-marker (point)) :language language
                   :live dictate-live)))
    (with-current-buffer log (erase-buffer))
    (setf (dictate--session-process session)
          (make-process
           :name "dictate-record"
           :command (append (list ffmpeg "-hide_banner" "-loglevel" "error"
                                  "-nostats")
                            input
                            (list "-t" (number-to-string dictate-max-seconds)
                                  "-ac" "1" "-ar" "16000" "-f" "s16le" "-"))
           :connection-type 'pipe
           :coding 'no-conversion
           :noquery t
           :stderr log
           :filter (lambda (_process string) (dictate--receive session string))
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (dictate--recording-ended session process)))))
    (setq dictate--recording session)
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

(defun dictate--frame (session frame)
  "Add FRAME to SESSION, ending the phrase after a long enough pause."
  (let* ((level (dictate--frame-level frame))
         (floor (dictate--session-floor session))
         (speech (> level (dictate--threshold session)))
         (in-phrase (dictate--session-frames session)))
    ;; The noise floor follows quiet stretches down at once, and drifts
    ;; up slowly, so a noisy room is learnt within a few seconds.
    (setf (dictate--session-floor session)
          (cond ((or (null floor) (< level floor)) (float level))
                (t (+ floor (* 0.002 (- level floor))))))
    (setf (dictate--session-level session) level)
    (cond
     (in-phrase
      (push frame (dictate--session-frames session))
      (cl-incf (dictate--session-count session))
      (if speech
          (progn (cl-incf (dictate--session-speech session))
                 (setf (dictate--session-silence session) 0))
        (cl-incf (dictate--session-silence session)))
      (let* ((fps dictate--frames-per-second)
             (count (dictate--session-count session))
             (silence (dictate--session-silence session))
             (max (* fps dictate-live-max-phrase)))
        ;; End the phrase after a pause; when it gets long, take a
        ;; shorter pause; and never let it grow past the maximum.
        (when (or (>= silence (* fps dictate-live-pause))
                  (and (>= count (* 0.8 max)) (>= silence (/ fps 4)))
                  (>= count max))
          (dictate--end-phrase session))))
     (speech
      (setf (dictate--session-frames session)
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
      (when (> (length (dictate--session-preroll session))
               (/ dictate--frames-per-second 4))
        (setf (dictate--session-preroll session)
              (butlast (dictate--session-preroll session))))))))

(defun dictate--end-phrase (session)
  "Send SESSION's current phrase to whisper, unless it was only a noise."
  (let ((frames (dictate--session-frames session))
        (speech (dictate--session-speech session)))
    (setf (dictate--session-frames session) nil
          (dictate--session-count session) 0
          (dictate--session-speech session) 0
          (dictate--session-silence session) 0)
    (when (and frames
               (>= speech (* dictate-live-min-speech
                             dictate--frames-per-second)))
      (dictate--enqueue session (apply #'concat (nreverse frames))))))

(defun dictate--recording-ended (session process)
  "Finish SESSION after ffmpeg PROCESS ended."
  (when (eq dictate--recording session)
    (setq dictate--recording nil))
  (setf (dictate--session-done session) t)
  (cond
   ((dictate--session-cancelled session)
    (setf (dictate--session-queue session) nil)
    (message "Dictate: cancelled"))
   ((dictate--session-live session)
    (dictate--end-phrase session))
   (t
    (let ((data (apply #'concat (nreverse (dictate--session-chunks session)))))
      (setf (dictate--session-chunks session) nil)
      (if (< (length data) 3200)          ; under a tenth of a second
          (let ((log (with-current-buffer " *dictate-ffmpeg*"
                       (string-trim (buffer-string)))))
            (message "Dictate: nothing was recorded%s"
                     (if (string-empty-p log) "" (concat ": " log))))
        (unless (dictate--session-stopping session)
          (message "Dictate: recording stopped after %d seconds"
                   dictate-max-seconds))
        (dictate--enqueue session data)))))
  (ignore process)
  (dictate--update-mode-line)
  (dictate--next session))

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

(defun dictate--enqueue (session data)
  "Save DATA as a WAV file and queue it for transcription in SESSION."
  (let ((wav (dictate--temp-file ".wav")))
    (dictate--write-wav data wav)
    (when dictate-keep-audio
      (make-directory dictate-directory t)
      (copy-file wav (expand-file-name "last.wav" dictate-directory) t))
    (setf (dictate--session-queue session)
          (append (dictate--session-queue session) (list wav)))
    (dictate--next session)))

;;;; Transcribing

(defun dictate--whisper-arguments (wav out language &optional hint)
  "Return the whisper-cli arguments to read WAV and write OUT.txt.
LANGUAGE is the spoken language.  HINT is text said just before."
  (let ((prompt (string-trim
                 (concat (or dictate-prompt "") " " (or hint "")))))
    (append (list "-m" (dictate--model)
                  "-f" wav
                  "-l" language
                  "-t" (number-to-string dictate-threads)
                  "-nt" "-np" "-otxt" "-of" out)
            (unless (string-empty-p prompt)
              (list "--prompt" prompt))
            dictate-extra-args)))

(defun dictate--next (session)
  "Transcribe the next phrase queued in SESSION, if whisper is free."
  (unless (dictate--session-busy session)
    (let ((wav (pop (dictate--session-queue session))))
      (cond
       (wav
        (setf (dictate--session-busy session) t)
        (dictate--transcribe
         wav (dictate--session-language session)
         (dictate--session-last-text session)
         (lambda (text)
           (setf (dictate--session-busy session) nil)
           (unless (dictate--session-cancelled session)
             (dictate--insert text session))
           (dictate--next session))))
       ((dictate--session-done session)
        (set-marker (dictate--session-marker session) nil))))))

(defun dictate--transcribe (wav language hint callback)
  "Turn WAV into text and call CALLBACK with it.
LANGUAGE is the spoken language and HINT the text said before.
CALLBACK gets nil when whisper fails."
  (let* ((out (file-name-sans-extension wav))
         (log (generate-new-buffer " *dictate-whisper*")))
    (setq dictate--jobs (1+ dictate--jobs))
    (dictate--update-mode-line)
    (make-process
     :name "dictate-whisper"
     :buffer log
     :command (cons (dictate--whisper)
                    (dictate--whisper-arguments wav out language hint))
     :connection-type 'pipe
     :noquery t
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (setq dictate--jobs (max 0 (1- dictate--jobs)))
         (dictate--update-mode-line)
         (let ((txt (concat out ".txt"))
               (text nil))
           (unwind-protect
               (if (file-exists-p txt)
                   (setq text (with-temp-buffer
                                (let ((coding-system-for-read 'utf-8))
                                  (insert-file-contents txt))
                                (dictate--clean (buffer-string))))
                 (message "Dictate: whisper failed: %s"
                          (with-current-buffer log
                            (string-trim
                             (buffer-substring
                              (max (point-min) (- (point-max) 300))
                              (point-max))))))
             (ignore-errors (delete-file txt))
             (ignore-errors (delete-file wav))
             (kill-buffer log))
           (funcall callback text)))))))

(defun dictate--clean (text)
  "Tidy whisper's TEXT: one line, no sound notes like [BLANK_AUDIO]."
  (let ((s (replace-regexp-in-string "\\[[^]\n]*\\]" " " text)))
    (setq s (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " s)))
    ;; Whisper puts noises in brackets; drop output that is only noises.
    (if (string-match-p "\\`\\(?:([^)]*)\\|\\*[^*]*\\*\\| \\)*\\'" s)
        ""
      s)))

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
    ;; Mid-sentence: lower case the first word, unless it is I or an acronym.
    (when (and before (not (string-empty-p s))
               (string-match-p "[[:alnum:],;]" (string before))
               (string-match-p "\\`[[:upper:]][[:lower:]]" s)
               (not (string-match-p "\\`I\\(?:'\\|\\b\\)" s)))
      (setq s (concat (downcase (substring s 0 1)) (substring s 1))))
    ;; Mid-sentence text should not end with whisper's full stop
    ;; when the sentence goes on after it.
    (when (and next (string-match-p "[[:lower:][:digit:]]" (string next))
               (string-match "\\.\\'" s))
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

(defun dictate--insert (text session)
  "Insert TEXT at SESSION's marker, which then moves past it.
When the buffer cannot be changed, TEXT goes to the kill ring."
  (let* ((marker (dictate--session-marker session))
         (buffer (marker-buffer marker))
         (case-fold-search nil))
    (cond
     ((null text))                      ; whisper failed and said so
     ((string-empty-p text)
      (unless (dictate--session-live session)
        (message "Dictate: heard nothing")))
     ((or (not (buffer-live-p buffer))
          (buffer-local-value 'buffer-read-only buffer))
      (if (dictate--session-copied session)
          (kill-append (concat " " text) nil)
        (kill-new text)
        (setf (dictate--session-copied session) t))
      (setf (dictate--session-last-text session) text)
      (message "Dictate: copied, paste with C-y: %s" (current-kill 0 t)))
     (t
      (with-current-buffer buffer
        ;; The last phrase ended with a full stop, but this one goes on
        ;; with the same sentence: take the full stop back.
        (when (and (dictate--session-period session)
                   (= (dictate--session-period session) marker)
                   (eq (char-before marker) ?.)
                   (string-match-p "\\`[[:lower:]]" text))
          (save-excursion
            (goto-char marker)
            (delete-char -1)))
        (let* ((context (dictate--context marker))
               (s (if dictate-smart-spacing
                      (apply #'dictate--fit text context)
                    text))
               (windows (seq-filter (lambda (w) (= (window-point w) marker))
                                    (get-buffer-window-list buffer nil t)))
               (at-point (= (point) marker))
               start end)
          (save-excursion
            (goto-char marker)
            (setq start (point))
            (insert s)
            (setq end (point)))
          (when at-point (goto-char end))
          (dolist (w windows) (set-window-point w end))
          (set-marker marker end)
          (setf (dictate--session-period session)
                (and (eq (char-before end) ?.) end)
                (dictate--session-last-text session) (string-trim s))
          (run-hook-with-args 'dictate-after-insert-hook start end)
          (unless (dictate--session-live session)
            (message "Dictate: %s" (string-trim s)))))))))

;;;; Commands

;;;###autoload
(defun dictate-toggle (&optional ask-language)
  "Start dictating at point, or stop and insert what was said.
With a prefix argument ASK-LANGUAGE, ask which language you will speak.
When `dictate-live' is non-nil, each phrase is typed after you pause."
  (interactive "P")
  (if dictate--recording
      (if (dictate--session-stopping dictate--recording)
          (message "Dictate: still stopping, one moment")
        (dictate--stop))
    (when (and buffer-read-only (not (minibufferp)))
      (message "Dictate: this buffer is read-only, the text will go to the kill ring"))
    (dictate--start
     (if ask-language
         (let ((language (read-string
                          (format "Language code, or auto (default %s): "
                                  dictate-language)
                          nil nil dictate-language)))
           (when (and (not (equal language "en"))
                      (string-match-p "\\.en\\.bin\\'" (dictate--model)))
             (message "Dictate: %s understands English only; download a model without .en"
                      (file-name-nondirectory (dictate--model)))
             (sit-for 1.5))
           language)
       dictate-language))))

;;;###autoload
(defun dictate-cancel ()
  "Stop recording, and throw away what was not typed yet."
  (interactive)
  (if dictate--recording
      (dictate--stop t)
    (message "Dictate: not recording")))

;;;; Setup

(defun dictate--run-steps (steps)
  "Run STEPS one after the other, each a (MESSAGE COMMAND FUNCTION).
COMMAND is a program and its arguments; FUNCTION, if non-nil, runs
after COMMAND succeeds.  Stop with a message at the first failure."
  (if (null steps)
      (message "Dictate: setup done; press %s to dictate (M-x dictate-check shows the details)"
               (substitute-command-keys "\\[dictate-toggle]"))
    (pcase-let ((`(,note ,command ,then) (car steps))
                (log (get-buffer-create " *dictate-setup*")))
      (message "Dictate: %s" note)
      (with-current-buffer log (erase-buffer))
      (make-process
       :name "dictate-setup" :buffer log :command command :noquery t
       :connection-type 'pipe
       :sentinel
       (lambda (process _event)
         (unless (process-live-p process)
           (if (= (process-exit-status process) 0)
               (progn (when then (funcall then))
                      (dictate--run-steps (cdr steps)))
             (message "Dictate: failed while %s: %s" note
                      (with-current-buffer log
                        (string-trim
                         (buffer-substring (max (point-min) (- (point-max) 300))
                                           (point-max))))))))))))

(defun dictate--download-step (url file note)
  "Return a step that downloads URL to FILE, showing NOTE."
  (let ((part (concat file ".part")))
    (list note
          (list dictate-curl-program "-fL" "--retry" "3" "-sS" "-o" part url)
          (lambda () (rename-file part file t)))))

;;;###autoload
(defun dictate-setup (model)
  "Download what dictation needs into `dictate-directory'.
That is whisper.cpp (on Windows, when it is not on PATH) and MODEL,
one of `dictate-models'.  Runs in the background."
  (interactive
   (list (completing-read
          "Model to download (default small.en): "
          (lambda (string pred action)
            (if (eq action 'metadata)
                `(metadata
                  (annotation-function
                   . ,(lambda (m)
                        (concat "  " (cdr (assoc m dictate-models))))))
              (complete-with-action action dictate-models string pred)))
          nil nil nil nil "small.en")))
  (unless (executable-find dictate-curl-program)
    (user-error "Dictate: curl not found"))
  (let* ((dir (file-name-as-directory (expand-file-name dictate-directory)))
         (models (dictate--models-directory))
         (model-file (expand-file-name (format "ggml-%s.bin" model) models))
         (zip (expand-file-name "whisper.zip" dir))
         (whisper-dir (expand-file-name "whisper" dir))
         (steps nil))
    (make-directory models t)
    (unless (dictate--whisper t)
      (unless (eq system-type 'windows-nt)
        (user-error "Dictate: install whisper.cpp with your package manager, or build it, then run this again"))
      (make-directory whisper-dir t)
      (setq steps
            (list (dictate--download-step
                   dictate-whisper-url zip "downloading whisper.cpp…")
                  (list "unpacking whisper.cpp…"
                        (list dictate-tar-program "-xf" zip "-C" whisper-dir)
                        (lambda ()
                          (delete-file zip)
                          (setq dictate--whisper-cache nil)
                          (unless (dictate--whisper t)
                            (error "whisper-cli.exe is not in the zip")))))))
    (if (file-exists-p model-file)
        (message "Dictate: %s is already downloaded" model)
      (setq steps
            (append steps
                    (list (dictate--download-step
                           (format dictate-model-url-format model) model-file
                           (format "downloading the %s model (%s)…" model
                                   (car (split-string
                                         (or (cdr (assoc model dictate-models)) "")
                                         ","))))))))
    ;; The newest model is the one used, so a new download takes over.
    (when (and (file-exists-p model-file) (null dictate-model))
      (set-file-times model-file))
    (dictate--run-steps steps)))

;;;###autoload
(defun dictate-check ()
  "Show what dictation will use, and what is missing."
  (interactive)
  (let* ((ffmpeg (executable-find dictate-ffmpeg-program))
         (whisper (dictate--whisper t))
         (model (dictate--model t))
         (mics (and ffmpeg (eq system-type 'windows-nt)
                    (ignore-errors (dictate--list-microphones))))
         (ok (lambda (v) (if v "OK " "-- "))))
    (with-current-buffer (get-buffer-create "*dictate-check*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Dictation setup\n\n")
        (insert (funcall ok ffmpeg) "ffmpeg: "
                (or ffmpeg "not found; run: winget install Gyan.FFmpeg, then restart Emacs")
                "\n")
        (insert (funcall ok whisper) "whisper-cli: "
                (or whisper "not found; run M-x dictate-setup") "\n")
        (insert (funcall ok model) "model: "
                (if model
                    (format "%s (%d MB)" model
                            (/ (or (file-attribute-size (file-attributes model)) 0)
                               1048576))
                  "none; run M-x dictate-setup")
                "\n")
        (when (eq system-type 'windows-nt)
          (insert (funcall ok mics) "microphones: "
                  (if mics (mapconcat #'car mics ", ") "none found") "\n")
          (insert "    using: " (or dictate-microphone
                                    (and mics (concat (caar mics) " (first found)"))
                                    "nothing")
                  "\n"))
        (insert "    language: " dictate-language
                (if dictate-prompt (concat "\n    prompt: " dictate-prompt) "")
                (format "\n    threads: %d\n" dictate-threads))
        (insert "\nPress " (substitute-command-keys "\\[dictate-toggle]")
                " to start dictating and again to stop.\n")
        (special-mode))
      (display-buffer (current-buffer)))))

(provide 'dictate)
;;; dictate.el ends here
