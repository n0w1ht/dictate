;;; dictate-test.el --- Tests for dictate.el -*- lexical-binding: t; -*-

;; Run: emacs -Q --batch -L . -l test/dictate-test.el -f ert-run-tests-batch-and-exit
;; The recording tests need ffmpeg; set DICTATE_TEST_WAV to a speech WAV,
;; and DICTATE_TEST_WHISPER / DICTATE_TEST_MODEL to run real whisper-cli.

;;; Code:

(require 'ert)
(require 'dictate)

(defconst dictate-test--dshow-new
  "[dshow @ 000001] \"Integrated Webcam\" (video)
[dshow @ 000001]   Alternative name \"@device_pnp_\\\\?\\usb#vid\"
[dshow @ 000001] \"Microphone Array (Intel® Smart Sound Technology)\" (audio)
[dshow @ 000001]   Alternative name \"@device_cm_{33D9A762}\\wave_{AB12}\"
[dshow @ 000001] \"Headset (Jabra)\" (audio)
[dshow @ 000001]   Alternative name \"@device_cm_{33D9A762}\\wave_{CD34}\"
dummy: Immediate exit requested
")

(defconst dictate-test--dshow-old
  "[dshow @ 0x1] DirectShow video devices (some may be both video and audio devices)
[dshow @ 0x1]  \"Integrated Webcam\"
[dshow @ 0x1]     Alternative name \"@device_pnp_x\"
[dshow @ 0x1] DirectShow audio devices
[dshow @ 0x1]  \"Microphone (Realtek(R) Audio)\"
[dshow @ 0x1]     Alternative name \"@device_cm_{1}\\wave_{2}\"
")

(ert-deftest dictate-test-parse-devices ()
  (should (equal (dictate--parse-dshow-devices dictate-test--dshow-new)
                 '(("Microphone Array (Intel® Smart Sound Technology)"
                    . "@device_cm_{33D9A762}\\wave_{AB12}")
                   ("Headset (Jabra)" . "@device_cm_{33D9A762}\\wave_{CD34}"))))
  (should (equal (dictate--parse-dshow-devices dictate-test--dshow-old)
                 '(("Microphone (Realtek(R) Audio)" . "@device_cm_{1}\\wave_{2}"))))
  (should (null (dictate--parse-dshow-devices "nothing here"))))

(ert-deftest dictate-test-device-argument ()
  (should (equal (dictate--device-argument '("Headset (Jabra)" . "@alt"))
                 "Headset (Jabra)"))
  (should (equal (dictate--device-argument '("Mic (Intel®)" . "@alt")) "@alt"))
  (should (equal (dictate--device-argument '("Mic (Intel®)")) "Mic (Intel®)")))

(ert-deftest dictate-test-input-arguments ()
  (let ((dictate-input-args nil) (dictate-microphone "Headset"))
    (let ((system-type 'windows-nt))
      (should (equal (dictate--input-arguments)
                     '("-f" "dshow" "-i" "audio=Headset"))))
    (let ((system-type 'gnu/linux) (dictate-microphone nil))
      (should (equal (dictate--input-arguments) '("-f" "pulse" "-i" "default"))))
    (let ((system-type 'darwin) (dictate-microphone nil))
      (should (equal (dictate--input-arguments)
                     '("-f" "avfoundation" "-i" ":0"))))
    (let ((dictate-input-args '("-i" "x.wav")))
      (should (equal (dictate--input-arguments) '("-i" "x.wav"))))))

(ert-deftest dictate-test-wav-header ()
  (let ((h (dictate--wav-header 32000)))
    (should (= (length h) 44))
    (should (not (multibyte-string-p h)))
    (should (equal (substring h 0 4) "RIFF"))
    (should (equal (substring h 4 8) (unibyte-string 36 125 0 0)))
    (should (equal (substring h 40 44) (unibyte-string 0 125 0 0)))))

(ert-deftest dictate-test-write-wav ()
  (let ((wav (make-temp-file "dt" nil ".wav")))
    (unwind-protect
        (progn
          (dictate--write-wav (make-string 32001 7) wav) ; odd byte dropped
          (should (= (file-attribute-size (file-attributes wav)) (+ 44 32000)))
          (when (executable-find "ffprobe")
            (let ((out (shell-command-to-string
                        (format "ffprobe -v error -show_entries stream=sample_rate,channels:format=duration -of csv=p=0 %s"
                                (shell-quote-argument wav)))))
              (should (string-match-p "16000,1" out))
              (should (string-match-p "1\\.0" out)))))
      (delete-file wav))))

(ert-deftest dictate-test-clean ()
  (should (equal (dictate--clean " Hello there.\n How are you?\n") "Hello there. How are you?"))
  (should (equal (dictate--clean "[BLANK_AUDIO]\n") ""))
  (should (equal (dictate--clean " (upbeat music)\n") ""))
  (should (equal (dictate--clean " [Music] The heart has four chambers.")
                 "The heart has four chambers."))
  (should (equal (dictate--clean "The drug (an ACE inhibitor) works.")
                 "The drug (an ACE inhibitor) works.")))

(ert-deftest dictate-test-fit ()
  ;; Start of a line: as whisper wrote it.
  (should (equal (dictate--fit "The heart." nil nil t) "The heart."))
  ;; After a full stop and a space.
  (should (equal (dictate--fit "The heart." ?. nil t) "The heart."))
  ;; After a full stop without a space: add one.
  (should (equal (dictate--fit "The heart." ?. nil nil) " The heart."))
  ;; Mid-sentence: lower case, space added.
  (should (equal (dictate--fit "Stroke volume." ?s nil nil) " stroke volume."))
  (should (equal (dictate--fit "Stroke volume." ?, nil t) "stroke volume."))
  ;; I and acronyms keep their capitals.
  (should (equal (dictate--fit "I think so." ?d nil t) "I think so."))
  (should (equal (dictate--fit "ACE inhibitors." ?d nil t) "ACE inhibitors."))
  ;; Before more text: no full stop, space after.
  (should (equal (dictate--fit "Cardiac output" ?e ?i t) "cardiac output "))
  (should (equal (dictate--fit "Cardiac output." ?e ?i t) "cardiac output "))
  ;; Before a new sentence: keep the full stop.
  (should (equal (dictate--fit "One." ?. ?\s t ?T) "One."))
  (should (equal (dictate--fit "One." ?. ?\s t ?t) "One"))
  ;; Before punctuation: no space.
  (should (equal (dictate--fit "cardiac output" ?e ?. t) "cardiac output"))
  ;; After an open bracket: no space.
  (should (equal (dictate--fit "Cardiac output" ?\( ?\) nil) "Cardiac output")))

(defun dictate-test--session (pos &rest args)
  "Return a session inserting at POS in the current buffer."
  (apply #'dictate--session-create :marker (copy-marker pos) args))

(ert-deftest dictate-test-insert ()
  (with-temp-buffer
    (insert "Heart rate times  equals cardiac output.")
    (goto-char 18)
    (let ((session (dictate-test--session 18)))
      (dictate--insert "Stroke volume." session)
      (should (equal (buffer-string)
                     "Heart rate times stroke volume equals cardiac output."))
      (should (= (point) 31))
      (should (= (dictate--session-marker session) 31)))))

(ert-deftest dictate-test-insert-point-elsewhere ()
  (with-temp-buffer
    (insert "One. ")
    (let ((session (dictate-test--session (point-max))))
      (insert "Typed meanwhile.")
      (goto-char (point-max))
      (dictate--insert "Two." session)
      (should (equal (buffer-string) "One. Two. Typed meanwhile."))
      (should (= (point) (point-max))))))

(ert-deftest dictate-test-insert-phrases ()
  ;; Phrases follow each other; a full stop whisper put at a pause is
  ;; taken back when the next phrase carries on the sentence.
  (with-temp-buffer
    (insert "Notes: ")
    (let ((session (dictate-test--session (point-max) :live t)))
      (dictate--insert "The heart pumps." session)
      (dictate--insert "blood to the lungs." session)
      (should (equal (buffer-string) "Notes: The heart pumps blood to the lungs."))
      (dictate--insert "Then it returns." session)
      (should (equal (buffer-string)
                     "Notes: The heart pumps blood to the lungs. Then it returns."))
      (should (= (point) (point-max)))
      (should (equal (dictate--session-last-text session) "Then it returns.")))))

(ert-deftest dictate-test-insert-keeps-typed-full-stop ()
  ;; A full stop the user typed is never removed.
  (with-temp-buffer
    (insert "Done.")
    (let ((session (dictate-test--session (point-max) :live t)))
      (dictate--insert "and more." session)
      (should (equal (buffer-string) "Done. and more.")))))

(ert-deftest dictate-test-insert-read-only ()
  (let ((kill-ring nil))
    (with-temp-buffer
      (insert "fixed")
      (setq buffer-read-only t)
      (let ((session (dictate-test--session 1 :live t)))
        (dictate--insert "Copied text." session)
        (dictate--insert "More text." session))
      (should (equal (buffer-string) "fixed"))
      (should (equal (car kill-ring) "Copied text. More text."))
      (should (= (length kill-ring) 1)))))

(ert-deftest dictate-test-insert-nothing ()
  (with-temp-buffer
    (dictate--insert "" (dictate-test--session 1))
    (dictate--insert nil (dictate-test--session 1))
    (should (equal (buffer-string) ""))))

(ert-deftest dictate-test-whisper-arguments ()
  (let ((dictate-model "/m/ggml-small.en.bin")
        (dictate-threads 3)
        (dictate-prompt "Tachycardia.")
        (dictate-extra-args '("-sns")))
    (should (equal (dictate--whisper-arguments "/t/a.wav" "/t/a" "en")
                   '("-m" "/m/ggml-small.en.bin" "-f" "/t/a.wav" "-l" "en"
                     "-t" "3" "-nt" "-np" "-otxt" "-of" "/t/a"
                     "--prompt" "Tachycardia." "-sns"))))
  (let ((dictate-model "/m/x.bin") (dictate-prompt "") (dictate-extra-args nil)
        (dictate-threads 1))
    (should-not (member "--prompt" (dictate--whisper-arguments "a" "b" "en"))))
  ;; The last phrase is passed on as a hint.
  (let ((dictate-model "/m/x.bin") (dictate-prompt "Cardiology.")
        (dictate-extra-args nil) (dictate-threads 1))
    (should (equal (member "--prompt" (dictate--whisper-arguments
                                       "a" "b" "en" "The heart pumps."))
                   '("--prompt" "Cardiology. The heart pumps.")))))

(ert-deftest dictate-test-find-model-and-whisper ()
  (let* ((dir (make-temp-file "dictate-dir" t))
         (dictate-directory dir)
         (dictate-model nil)
         (dictate-whisper-program nil)
         (dictate--whisper-cache nil)
         (exec-path nil))
    (unwind-protect
        (progn
          (should-not (dictate--model t))
          (should-not (dictate--whisper t))
          (should-error (dictate--model) :type 'user-error)
          (make-directory (expand-file-name "models" dir))
          (make-directory (expand-file-name "whisper/Release" dir) t)
          (let ((old (expand-file-name "models/ggml-base.en.bin" dir))
                (new (expand-file-name "models/ggml-small.en.bin" dir)))
            (write-region "" nil old)
            (set-file-times old (time-subtract nil 100))
            (write-region "" nil new)
            (should (equal (dictate--model) new)))
          (let ((exe (expand-file-name "whisper/Release/whisper-cli.exe" dir)))
            (write-region "" nil exe)
            (should (equal (dictate--whisper) exe))))
      (delete-directory dir t))))

(ert-deftest dictate-test-mode-line ()
  (let ((global-mode-string nil) (dictate--recording nil) (dictate--jobs 0))
    (dictate--update-mode-line)
    (should-not (member dictate--mode-line global-mode-string))
    (setq dictate--recording (dictate--session-create))
    (dictate--update-mode-line)
    (should (member dictate--mode-line global-mode-string))
    (should (string-match-p "Dictating" (dictate--mode-line-string)))
    (setf (dictate--session-live dictate--recording) t)
    (should (string-match-p "Listening" (dictate--mode-line-string)))
    (setf (dictate--session-frames dictate--recording) (list "x"))
    (should (string-match-p "Hearing" (dictate--mode-line-string)))
    (setq dictate--recording nil dictate--jobs 1)
    (should (string-match-p "Transcribing" (dictate--mode-line-string)))
    (setq dictate--jobs 0)
    (dictate--update-mode-line)
    (should-not (member dictate--mode-line global-mode-string))))

;;;; Pause detection

(defun dictate-test--frames (level seconds)
  "Return SECONDS of frames whose samples alternate between +LEVEL and -LEVEL."
  (let* ((lo (logand level 255)) (hi (logand (ash level -8) 255))
         (neg (logand (- 65536 level) 65535))
         (frame (apply #'unibyte-string
                       (apply #'append
                              (make-list 160 (list lo hi (logand neg 255)
                                                   (ash neg -8)))))))
    (make-list (round (* seconds 50)) frame)))

(defun dictate-test--feed (frames)
  "Feed FRAMES to a live session; return the phrases cut, in seconds."
  (let* ((phrases nil)
         (session (dictate--session-create :live t)))
    (cl-letf (((symbol-function 'dictate--enqueue)
               (lambda (_s data) (push (/ (length data) 32000.0) phrases))))
      ;; Arrive in uneven chunks, as from a pipe.
      (let ((data (apply #'concat frames)) (i 0))
        (while (< i (length data))
          (let ((j (min (length data) (+ i 1000 (random 3000)))))
            (dictate--receive session (substring data i j))
            (setq i j))))
      (dictate--end-phrase session))
    (nreverse phrases)))

(ert-deftest dictate-test-frame-level ()
  (should (= (dictate--frame-level (car (dictate-test--frames 1000 0.02))) 1000))
  (should (= (dictate--frame-level (car (dictate-test--frames 0 0.02))) 0)))

(ert-deftest dictate-test-pauses-split-phrases ()
  (let ((dictate-live-pause 0.7) (dictate-live-min-speech 0.3)
        (dictate-live-max-phrase 25) (dictate-live-sensitivity 3.0)
        (dictate-live-min-level 150))
    (let ((phrases (dictate-test--feed
                    (append (dictate-test--frames 40 1.0)
                            (dictate-test--frames 3000 1.5)
                            (dictate-test--frames 40 0.4) ; short gap: same phrase
                            (dictate-test--frames 3000 1.0)
                            (dictate-test--frames 40 1.0)
                            (dictate-test--frames 3000 0.1) ; a click: dropped
                            (dictate-test--frames 40 1.0)
                            (dictate-test--frames 3000 2.0)))))
      (should (= (length phrases) 2))
      ;; 0.24 s before + 1.5 + 0.4 + 1.0 + 0.7 s pause
      (should (< 3.7 (car phrases) 3.9))
      ;; The last phrase is still open at the end and is sent then.
      (should (< 2.2 (cadr phrases) 2.3)))))

(ert-deftest dictate-test-steady-sound-is-not-speech ()
  ;; A steady hum louder than the minimum (a fan) is not taken for speech.
  (let ((dictate-live-pause 0.7) (dictate-live-min-speech 0.3)
        (dictate-live-max-phrase 25) (dictate-live-sensitivity 3.0)
        (dictate-live-min-level 150))
    (should (null (dictate-test--feed (dictate-test--frames 1000 5))))))

(ert-deftest dictate-test-noisy-room ()
  ;; Background noise above the minimum level is learnt, so pauses
  ;; still end phrases.
  (let ((dictate-live-pause 0.7) (dictate-live-min-speech 0.3)
        (dictate-live-max-phrase 25) (dictate-live-sensitivity 3.0)
        (dictate-live-min-level 150))
    (should (= 2 (length (dictate-test--feed
                          (append (dictate-test--frames 400 1.0)
                                  (dictate-test--frames 4000 1.0)
                                  (dictate-test--frames 400 1.0)
                                  (dictate-test--frames 4000 1.0)
                                  (dictate-test--frames 400 1.0))))))))

(ert-deftest dictate-test-long-phrase-is-cut ()
  (let ((dictate-live-pause 0.7) (dictate-live-min-speech 0.3)
        (dictate-live-max-phrase 5) (dictate-live-sensitivity 3.0)
        (dictate-live-min-level 150))
    ;; Words with short gaps between them, for 12 seconds, no pause.
    (let ((phrases (dictate-test--feed
                    (apply #'append
                           (make-list 46 (append (dictate-test--frames 3000 0.2)
                                                 (dictate-test--frames 40 0.06)))))))
      (should (= (length phrases) 3))
      (should (<= (apply #'max phrases) 5.0)))))

;;;; Recording end to end, with ffmpeg reading a file instead of a microphone

(defun dictate-test--wait (pred seconds)
  "Wait until PRED is true or SECONDS pass."
  (let ((end (+ (float-time) seconds)))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun dictate-test--fake-whisper (dir text)
  "Write a fake whisper-cli in DIR that checks the WAV and writes TEXT.
TEXT may hold several phrases separated by |; call N writes the Nth.
Each call appends its arguments and the WAV length to DIR/calls."
  (let ((f (expand-file-name "whisper-cli" dir)))
    (with-temp-file f
      (insert "#!/bin/sh\n"
              "dir=" (shell-quote-argument dir) "\n"
              "args=\"$*\"\n"
              "while [ $# -gt 0 ]; do case \"$1\" in -of) of=\"$2\"; shift;; -f) wav=\"$2\"; shift;; esac; shift; done\n"
              "len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 \"$wav\") || exit 3\n"
              "n=$(( $(cat \"$dir/count\" 2>/dev/null || echo 0) + 1 )); echo $n > \"$dir/count\"\n"
              "echo \"$len $args\" >> \"$dir/calls\"\n"
              "sleep 0.3\n"
              "printf '%s\\n' " (shell-quote-argument text)
              " | cut -d'|' -f$n > \"$of.txt\"\n"))
    (set-file-modes f #o755)
    f))

(defun dictate-test--calls (dir)
  "Return the lines logged by the fake whisper in DIR."
  (let ((f (expand-file-name "calls" dir)))
    (and (file-exists-p f)
         (split-string (with-temp-buffer (insert-file-contents f)
                                         (buffer-string))
                       "\n" t))))

(defmacro dictate-test--with-setup (text &rest body)
  "Run BODY with ffmpeg reading the test WAV and a fake whisper writing TEXT."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "dictate-e2e" t))
          (wav (or (getenv "DICTATE_TEST_WAV")
                   (let ((w (expand-file-name "tone.wav" dir)))
                     (call-process "ffmpeg" nil nil nil "-v" "error" "-f" "lavfi"
                                   "-i" "sine=frequency=440:duration=8" w)
                     w)))
          (dictate-input-args (list "-re" "-i" wav))
          (dictate-whisper-program (or (getenv "DICTATE_TEST_WHISPER")
                                       (dictate-test--fake-whisper dir ,text)))
          (dictate-model (or (getenv "DICTATE_TEST_MODEL")
                             (let ((m (expand-file-name "ggml-test.bin" dir)))
                               (write-region "" nil m) m)))
          (dictate-keep-audio nil)
          (dictate-live nil)
          (dictate--recording nil)
          (dictate--jobs 0))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(ert-deftest dictate-test-record-stop-insert ()
  (skip-unless (executable-find "ffmpeg"))
  (dictate-test--with-setup "The kidney filters blood."
    (with-temp-buffer
      (insert "Notes: ")
      (dictate-toggle)
      (should dictate--recording)
      (let ((process (dictate--session-process dictate--recording)))
        (sleep-for 2)
        (dictate-toggle)                ; sends q to ffmpeg
        (should (dictate-test--wait (lambda () (not (process-live-p process))) 10))
        ;; It stopped because of q, not the kill timer.
        (should (= (process-exit-status process) 0)))
      (should (dictate-test--wait (lambda () (> (buffer-size) 8)) 60))
      (should (dictate-test--wait (lambda () (= dictate--jobs 0)) 10))
      (if (getenv "DICTATE_TEST_WHISPER")
          (message "Real whisper wrote: %S" (buffer-string))
        (should (equal (buffer-string) "Notes: The kidney filters blood."))))))

(ert-deftest dictate-test-live-phrases ()
  ;; Two tone bursts with a pause between them, like two phrases.
  (skip-unless (executable-find "ffmpeg"))
  (dictate-test--with-setup "The heart pumps.|blood to the lungs."
    (let ((dictate-live t)
          (dictate-live-pause 0.7)
          (dictate-live-min-speech 0.3)
          (dictate-live-sensitivity 3.0)
          (dictate-live-min-level 150)
          (wav (expand-file-name "phrases.wav" dir)))
      (call-process "ffmpeg" nil nil nil "-v" "error" "-f" "lavfi" "-i"
                    "aevalsrc=0.15*sin(2*PI*440*t)*(between(t\\,1\\,2.5)+between(t\\,3.7\\,5.2))+0.002*random(0):s=16000:d=8"
                    wav)
      (setq dictate-input-args (list "-re" "-i" wav))
      (with-temp-buffer
        (insert "Notes: ")
        (dictate-toggle)
        (let ((process (dictate--session-process dictate--recording)))
          ;; The first phrase is typed while still recording.
          (should (dictate-test--wait
                   (lambda () (string-match-p "pumps" (buffer-string))) 6))
          (should (process-live-p process))
          (sleep-for 1.5)
          (dictate-toggle)
          (should (dictate-test--wait (lambda () (not (process-live-p process))) 10)))
        (should (dictate-test--wait
                 (lambda () (string-match-p "lungs" (buffer-string))) 10))
        (should (equal (buffer-string) "Notes: The heart pumps blood to the lungs."))
        (should (= (point) (point-max)))
        (let ((calls (dictate-test--calls dir)))
          (should (= (length calls) 2))
          ;; The first phrase is given to whisper as a hint for the second.
          (should (string-match-p "--prompt The heart pumps\\." (nth 1 calls))))))))

(ert-deftest dictate-test-cancel ()
  (skip-unless (executable-find "ffmpeg"))
  (dictate-test--with-setup "Should not appear."
    (with-temp-buffer
      (dictate-toggle)
      (let ((process (dictate--session-process dictate--recording)))
        (sleep-for 1)
        (dictate-cancel)
        (should (dictate-test--wait (lambda () (not (process-live-p process))) 10))
        (accept-process-output nil 0.5)
        (should (null dictate--recording))
        (should (= dictate--jobs 0))
        (should (equal (buffer-string) ""))))))

(ert-deftest dictate-test-ffmpeg-error ()
  (skip-unless (executable-find "ffmpeg"))
  (dictate-test--with-setup "x"
    (let ((dictate-input-args '("-f" "lavfi" "-i" "nosuchfilter")))
      (with-temp-buffer
        (dictate-toggle)
        (let ((process (dictate--session-process dictate--recording)))
          (should (dictate-test--wait (lambda () (not (process-live-p process))) 10))
          (accept-process-output nil 0.2)
          (should (null dictate--recording))
          (should (= dictate--jobs 0)))))))

(ert-deftest dictate-test-setup-download ()
  (skip-unless (and (executable-find "curl") (executable-find "ffmpeg")))
  (let* ((dir (make-temp-file "dictate-setup" t))
         (src (expand-file-name "ggml-tiny.en.bin" dir))
         (dictate-directory (expand-file-name "home/" dir))
         (dictate-model nil)
         (dictate-whisper-program (dictate-test--fake-whisper dir "x"))
         (dictate-model-url-format (concat "file://" dir "/ggml-%s.bin")))
    (unwind-protect
        (progn
          (write-region "model" nil src)
          (dictate-setup "tiny.en")
          (should (dictate-test--wait
                   (lambda () (dictate--model t)) 10))
          (should (string-suffix-p "models/ggml-tiny.en.bin" (dictate--model)))
          (should-not (file-exists-p (concat (dictate--model) ".part"))))
      (delete-directory dir t))))

(provide 'dictate-test)
;;; dictate-test.el ends here
