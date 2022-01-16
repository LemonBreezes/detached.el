;;; dtache.el --- Run and interact with detached shell commands -*- lexical-binding: t -*-

;; Copyright (C) 2020-2022 Niklas Eklund

;; Author: Niklas Eklund <niklas.eklund@posteo.net>
;; URL: https://www.gitlab.com/niklaseklund/dtache.git
;; Version: 0.3
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience processes

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The dtache package allows users to run shell commands detached from
;; Emacs.  These commands are launched in sessions, using the program
;; dtach[1].  These sessions can be easily created through the command
;; `dtache-shell-command', or any of the commands provided by the
;; `dtache-shell', `dtache-eshell' and `dtache-compile' extensions.

;; When a session is created, dtache makes sure that Emacs is attached
;; to it the same time, which makes it a seamless experience for the
;; users.  The `dtache' package internaly creates a `dtache-session'
;; for all commands.

;; [1] https://github.com/crigler/dtach

;;; Code:

;;;; Requirements

(require 'autorevert)
(require 'filenotify)
(require 'simple)
(require 'tramp)

(declare-function dtache-eshell-get-dtach-process "dtache-eshell")

;;;; Variables

;;;;; Customizable

(defcustom dtache-session-directory (expand-file-name "dtache" (temporary-file-directory))
  "The directory to store sessions."
  :type 'string
  :group 'dtache)

(defcustom dtache-db-directory user-emacs-directory
  "The directory to store the `dtache' database."
  :type 'string
  :group 'dtache)

(defcustom dtache-dtach-program "dtach"
  "The name of the `dtach' program."
  :type 'string
  :group 'dtache)

(defcustom dtache-shell-program "bash"
  "Shell to run the dtach command in."
  :type 'string
  :group 'dtache)

(defcustom dtache-timer-configuration '(:seconds 10 :repeat 60 :function run-with-timer)
  "A property list defining how often to run a timer."
  :type 'plist
  :group 'dtache)

(defcustom dtache-env nil
  "The name of, or path to, the `dtache' environment script."
  :type 'string
  :group 'dtache)

(defcustom dtache-annotation-format
  '((:width 3 :function dtache--state-str :face dtache-state-face)
    (:width 3 :function dtache--status-str :face dtache-failure-face)
    (:width 10 :function dtache--session-host :face dtache-host-face)
    (:width 40 :function dtache--working-dir-str :face dtache-working-dir-face)
    (:width 30 :function dtache--metadata-str :face dtache-metadata-face)
    (:width 10 :function dtache--duration-str :face dtache-duration-face)
    (:width 8 :function dtache--size-str :face dtache-size-face)
    (:width 12 :function dtache--creation-str :face dtache-creation-face))
  "The format of the annotations."
  :type '(repeat symbol)
  :group 'dtache)

(defcustom dtache-max-command-length 90
  "Maximum length of displayed command."
  :type 'integer
  :group 'dtache)

(defcustom dtache-tail-interval 2
  "Interval in seconds for the update rate when tailing a session."
  :type 'integer
  :group 'dtache)

(defcustom dtache-shell-command-session-action
  '(:attach dtache-attach
            :view dtache-view-dwim
            :run dtache-shell-command)
  "Actions for a session created with `dtache-shell-command'."
  :group 'dtache
  :type 'plist)

(defcustom dtache-nonattachable-commands nil
  "A list of commands which `dtache' should consider nonattachable."
  :type '(repeat (regexp :format "%v"))
  :group 'dtache)

(defcustom dtache-notification-function #'dtache-state-transition-notification
  "Variable to set which function to use to issue a notification."
  :type 'function
  :group 'dtache)

;;;;; Public

(defvar dtache-enabled nil)
(defvar dtache-session-mode nil
  "Mode of operation for session.
Valid values are: create, new and attach")
(defvar dtache-session-origin nil
  "Variable to specify the origin of the session.")
(defvar dtache-session-action nil
  "A property list of actions for a session.")
(defvar dtache-shell-command-history nil
  "History of commands run with `dtache-shell-command'.")

(defvar dtache-compile-hooks nil
  "Hooks to run when compiling a session.")
(defvar dtache-metadata-annotators-alist nil
  "An alist of annotators for metadata.")

(defconst dtache-session-version "0.3.0"
  "The version of `dtache-session'.
This version is encoded as [package-version].[revision].")

(defvar dtache-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" #'dtache-attach)
    (define-key map "c" #'dtache-post-compile-session)
    (define-key map "d" #'dtache-delete-session)
    (define-key map "i" #'dtache-insert-session-command)
    (define-key map "k" #'dtache-kill-session)
    (define-key map "o" #'dtache-open-output)
    (define-key map "r" #'dtache-rerun-session)
    (define-key map "t" #'dtache-tail-output)
    (define-key map "w" #'dtache-copy-session-command)
    (define-key map "W" #'dtache-copy-session-output)
    (define-key map "=" #'dtache-diff-session)
    map))

;;;;; Faces

(defgroup dtache-faces nil
  "Faces used by `dtache'."
  :group 'dtache
  :group 'faces)

(defface dtache-metadata-face
  '((t :inherit font-lock-builtin-face))
  "Face used to highlight metadata in `dtache'.")

(defface dtache-failure-face
  '((t :inherit error))
  "Face used to highlight failure in `dtache'.")

(defface dtache-state-face
  '((t :inherit success))
  "Face used to highlight state in `dtache'.")

(defface dtache-duration-face
  '((t :inherit font-lock-builtin-face))
  "Face used to highlight duration in `dtache'.")

(defface dtache-size-face
  '((t :inherit font-lock-function-name-face))
  "Face used to highlight size in `dtache'.")

(defface dtache-creation-face
  '((t :inherit font-lock-comment-face))
  "Face used to highlight date in `dtache'.")

(defface dtache-working-dir-face
  '((t :inherit font-lock-variable-name-face))
  "Face used to highlight working directory in `dtache'.")

(defface dtache-host-face
  '((t :inherit font-lock-constant-face))
  "Face used to highlight host in `dtache'.")

(defface dtache-identifier-face
  '((t :inherit font-lock-comment-face))
  "Face used to highlight identifier in `dtache'.")

;;;;; Private

(defvar dtache--sessions-initialized nil
  "Sessions are initialized.")
(defvar dtache--sessions nil
  "A list of sessions.")
(defvar dtache--buffer-session nil
  "The `dtache-session' session in current buffer.")
(defvar dtache--current-session nil
  "The current session.")
(make-variable-buffer-local 'dtache--buffer-session)
(defvar dtache--session-candidates nil
  "An alist of session candidates.")

(defconst dtache--shell-command-buffer "*Dtache Shell Command*"
  "Name of the `dtache-shell-command' buffer.")
(defconst dtache--dtach-eof-message "\\[EOF - dtach terminating\\]"
  "Message printed when `dtach' terminates.")
(defconst dtache--dtach-detached-message "\\[detached\\]\^M"
  "Message printed when detaching from `dtach'.")
(defconst dtache--dtach-detach-character "\C-\\"
  "Character used to detach from a session.")

;;;; Data structures

(cl-defstruct (dtache-session (:constructor dtache--session-create)
                              (:conc-name dtache--session-))
  (id nil :read-only t)
  (command nil :read-only t)
  (origin nil :read-only t)
  (working-directory nil :read-only t)
  (creation-time nil :read-only t)
  (directory nil :read-only t)
  (metadata nil :read-only t)
  (host nil :read-only t)
  (attachable nil :read-only t)
  (action nil :read-only t)
  (status nil)
  (duration nil)
  (log-size nil)
  (state nil))

;;;; Commands

;;;###autoload
(defun dtache-shell-command (command &optional suppress-output)
  "Execute COMMAND asynchronously with `dtache'.

Optionally SUPPRESS-OUTPUT."
  (interactive
   (list
    (read-shell-command (if shell-command-prompt-show-cwd
                            (format-message "Dtache shell command in `%s': "
                                            (abbreviate-file-name
                                             default-directory))
                          "Dtache shell command: ")
                        nil 'dtache-shell-command-history)
    current-prefix-arg))
  (let* ((dtache-session-origin 'shell-command)
         (dtache-session-action dtache-shell-command-session-action)
         (dtache--current-session (dtache-create-session command)))
    (dtache-start-session command suppress-output)))

;;;###autoload
(defun dtache-open-session (session)
  "Open a `dtache' SESSION."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (if (eq 'active (dtache--determine-session-state session))
        (dtache--attach-session session)
      (dtache--view-session session))))

;;;###autoload
(defun dtache-post-compile-session (session)
  "Post `compile' by opening the output of a SESSION in `compilation-mode'."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (let ((buffer-name "*dtache-session-output*")
          (file
           (dtache--session-file session 'log))
          (tramp-verbose 1))
      (when (file-exists-p file)
        (with-current-buffer (get-buffer-create buffer-name)
          (setq-local buffer-read-only nil)
          (erase-buffer)
          (insert (dtache--session-output session))
          (setq-local default-directory
                      (dtache--session-working-directory session))
          (run-hooks 'dtache-compile-hooks)
          (dtache-log-mode)
          (compilation-minor-mode)
          (setq dtache--buffer-session session)
          (setq-local font-lock-defaults '(compilation-mode-font-lock-keywords t))
          (font-lock-mode)
          (read-only-mode))
        (pop-to-buffer buffer-name)))))

;;;###autoload
(defun dtache-rerun-session (session &optional suppress-output)
  "Rerun SESSION, optionally SUPPRESS-OUTPUT."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))
         current-prefix-arg))
  (when (dtache-valid-session session)
    (let* ((default-directory
             (dtache--session-working-directory session))
           (dtache-session-action (dtache--session-action session))
           (command (dtache--session-command session)))
      (if suppress-output
          (dtache-start-session command suppress-output)
        (if-let ((run-fun (plist-get (dtache--session-action session) :run)))
            (funcall run-fun command)
          (dtache-start-session command))))))

;;;###autoload
(defun dtache-attach (session)
  "Attach to SESSION."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (if (or (eq 'inactive (dtache--session-state session))
            (not (dtache--session-attachable session)))
        (dtache-open-output session)
      (let* ((dtache--current-session session)
             (dtache-session-mode 'attach)
             (inhibit-message t))
        (if (not (dtache--session-attachable session))
            (dtache-tail-output session)
          (cl-letf* (((symbol-function #'set-process-sentinel) #'ignore)
                     (buffer dtache--shell-command-buffer)
                     (dtach-command (dtache-dtach-command session t)))
            (funcall #'async-shell-command dtach-command buffer)
            (with-current-buffer buffer (setq dtache--buffer-session dtache--current-session))))))))

;;;###autoload
(defun dtache-copy-session-output (session)
  "Copy SESSION's log."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (with-temp-buffer
      (insert (dtache--session-output session))
      (kill-new (buffer-string)))))

;;;###autoload
(defun dtache-copy-session-command (session)
  "Copy SESSION command."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (kill-new (dtache--session-command session))))

;;;###autoload
(defun dtache-insert-session-command (session)
  "Insert SESSION."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (insert (dtache--session-command session))))

;;;###autoload
(defun dtache-delete-session (session)
  "Delete SESSION."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (if (eq 'active (dtache--determine-session-state session))
        (message "Kill session first before removing it.")
      (dtache--db-remove-entry session))))

;;;###autoload
(defun dtache-kill-session (session)
  "Send a TERM signal to SESSION."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (let* ((pid (dtache--session-pid session)))
      (when pid
        (dtache--kill-processes pid)))))

;;;###autoload
(defun dtache-open-output (session)
  "Open SESSION's output."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (let* ((buffer-name "*dtache-session-output*")
           (file-path
            (dtache--session-file session 'log))
           (tramp-verbose 1))
      (if (file-exists-p file-path)
          (progn
            (with-current-buffer (get-buffer-create buffer-name)
              (setq-local buffer-read-only nil)
              (erase-buffer)
              (insert (dtache--session-output session))
              (setq-local default-directory (dtache--session-working-directory session))
              (dtache-log-mode)
              (setq dtache--buffer-session session)
              (goto-char (point-max)))
            (pop-to-buffer buffer-name))
        (message "Dtache can't find file: %s" file-path)))))

;;;###autoload
(defun dtache-tail-output (session)
  "Tail SESSION's output."
  (interactive
   (list (dtache-completing-read (dtache-get-sessions))))
  (when (dtache-valid-session session)
    (if (eq 'active (dtache--determine-session-state session))
        (let* ((file-path
                (dtache--session-file session 'log))
               (tramp-verbose 1))
          (when (file-exists-p file-path)
            (find-file-other-window file-path)
            (setq dtache--buffer-session session)
            (dtache-tail-mode)
            (goto-char (point-max))))
      (dtache-open-output session))))

;;;###autoload
(defun dtache-diff-session (session1 session2)
  "Diff SESSION1 with SESSION2."
  (interactive
   (let ((sessions (dtache-get-sessions)))
     `(,(dtache-completing-read sessions)
       ,(dtache-completing-read sessions))))
  (when (and (dtache-valid-session session1)
             (dtache-valid-session session2))
    (let ((buffer1 "*dtache-session-output-1*")
          (buffer2 "*dtache-session-output-2*"))
      (with-current-buffer (get-buffer-create buffer1)
        (erase-buffer)
        (insert (dtache--session-header session1))
        (insert (dtache--session-output session1)))
      (with-current-buffer (get-buffer-create buffer2)
        (erase-buffer)
        (insert (dtache--session-header session2))
        (insert (dtache--session-output session2)))
      (ediff-buffers buffer1 buffer2))))

;;;###autoload
(defun dtache-detach-dwim ()
  "Detach from current session.

This command is only activated if `dtache--buffer-session' is set and
`dtache--determine-session-state' returns active.  For modes such as
compilation or `shell-command' the command will also kill the window."
  (interactive)
  (if (dtache-session-p dtache--buffer-session)
      (if-let ((command-or-compile
                (cond ((string-match dtache--shell-command-buffer (buffer-name)) t)
                      ((string-match "\*dtache-compilation" (buffer-name)) t)
                      ((eq major-mode 'dtache-log-mode) t)
                      ((eq major-mode 'dtache-tail-mode) t)
                      (t nil))))
          ;; `dtache-shell-command' or `dtache-compile'
          (let ((kill-buffer-query-functions nil))
            (when-let ((process (get-buffer-process (current-buffer))))
              (comint-simple-send process dtache--dtach-detach-character)
              (message "[detached]"))
            (setq dtache--buffer-session nil)
            (kill-buffer-and-window))
        (if (eq 'active (dtache--determine-session-state dtache--buffer-session))
            ;; `dtache-eshell'
            (if-let ((process (and (eq major-mode 'eshell-mode)
                                   (dtache-eshell-get-dtach-process))))
                (progn
                  (setq dtache--buffer-session nil)
                  (process-send-string process dtache--dtach-detach-character))
              ;; `dtache-shell'
              (let ((process (get-buffer-process (current-buffer))))
                (comint-simple-send process dtache--dtach-detach-character)
                (setq dtache--buffer-session nil)))
          (message "No active dtache-session found in buffer.")))
    (message "No dtache-session found in buffer.")))

;;;###autoload
(defun dtache-delete-sessions (&optional all-hosts)
  "Delete `dtache' sessions on current host, unless ALL-HOSTS."
  (interactive "P")
  (let* ((host (dtache--host))
         (sessions (if all-hosts
                       (dtache-get-sessions)
                     (seq-filter (lambda (it)
                                   (string= (dtache--session-host it) host))
                                 (dtache-get-sessions)))))
    (seq-do #'dtache--db-remove-entry sessions)))

;;;; Functions

;;;;; Session

(defun dtache-create-session (command)
  "Create a `dtache' session from COMMAND."
  (with-connection-local-variables
   (dtache--create-session-directory)
   (let ((session
          (dtache--session-create :id (intern (dtache--create-id command))
                                  :command command
                                  :origin dtache-session-origin
                                  :action dtache-session-action
                                  :working-directory (dtache--get-working-directory)
                                  :attachable (dtache-attachable-command-p command)
                                  :creation-time (time-to-seconds (current-time))
                                  :status 'unknown
                                  :log-size 0
                                  :directory (file-name-as-directory dtache-session-directory)
                                  :host (dtache--host)
                                  :metadata (dtache-metadata)
                                  :state 'active)))
     (dtache--db-insert-entry session)
     (dtache--start-session-monitor session)
     session)))

(defun dtache-start-session (command &optional suppress-output)
  "Start a `dtache' session running COMMAND.

Optionally SUPPRESS-OUTPUT."
  (let ((inhibit-message t)
        (dtache-enabled t)
        (dtache--current-session
         (or dtache--current-session
             (dtache-create-session command))))
    (if-let ((run-in-background
              (and (or suppress-output
                       (eq dtache-session-mode 'create)
                       (not (dtache--session-attachable dtache--current-session)))))
             (dtache-session-mode 'create))
        (progn (setq dtache-enabled nil)
               (apply #'start-file-process-shell-command
                      `("dtache" nil ,(dtache-dtach-command dtache--current-session t))))
      (cl-letf* ((dtache-session-mode 'create-and-attach)
                 ((symbol-function #'set-process-sentinel) #'ignore)
                 (buffer (generate-new-buffer-name dtache--shell-command-buffer)))
        (setq dtache-enabled nil)
        (funcall #'async-shell-command (dtache-dtach-command dtache--current-session t) buffer)
        (with-current-buffer buffer (setq dtache--buffer-session dtache--current-session))))))

(defun dtache-session-candidates (sessions)
  "Return an alist of SESSIONS candidates."
  (setq dtache--session-candidates
        (thread-last sessions
                     (seq-map (lambda (it)
                                `(,(dtache--session-truncate-command it)
                                  . ,it)))
                     (dtache--session-deduplicate)
                     (seq-map (lambda (it)
                                ;; Max width is the ... padding + width of identifier
                                (setcar it (truncate-string-to-width (car it) (+ 3 6 dtache-max-command-length) 0 ?\s))
                                it)))))

(defun dtache-session-annotation (item)
  "Associate ITEM to a session and return ts annotation."
  (let ((session (cdr (assoc item dtache--session-candidates))))
    (mapconcat
     #'identity
     (cl-loop for annotation in dtache-annotation-format
              collect (let ((str (funcall (plist-get annotation :function) session)))
                        (truncate-string-to-width
                         (propertize str 'face (plist-get annotation :face))
                         (plist-get annotation :width)
                         0 ?\s)))
     "   ")))

;;;###autoload
(defun dtache-setup ()
  "Initialize `dtache'."

  ;; Initialize sessions
  (unless dtache--sessions-initialized
    (unless (file-exists-p dtache-db-directory)
      (make-directory dtache-db-directory t))

    ;; Update database
    (dtache--db-initialize)
    (seq-do (lambda (session)
              ;; Remove missing local sessions
              (if (and (string= "localhost" (dtache--session-host session))
                       (dtache--session-missing-p session))
                  (dtache--db-remove-entry session)

                ;; Update local active sessions
                (when (and (string= "localhost" (dtache--session-host session))
                           (eq 'active (dtache--session-state session)))
                  (dtache--update-session session))))
            (dtache--db-get-sessions))

    ;; Start monitors
    (thread-last (dtache--db-get-sessions)
                 (seq-filter (lambda (it) (eq 'active (dtache--session-state it))))
                 (seq-remove (lambda (it) (when (dtache--session-missing-p it)
                                            (dtache--db-remove-entry it)
                                            t)))
                 (seq-do #'dtache--start-session-monitor))

    ;; Add `dtache-shell-mode'
    (add-hook 'shell-mode-hook #'dtache-shell-mode)))

(defun dtache-valid-session (session)
  "Ensure that SESSION is valid.

If session is not valid trigger an automatic cleanup on SESSION's host."
  (when (dtache-session-p session)
    (if (not (dtache--session-missing-p session))
        t
      (let ((host (dtache--session-host session)))
        (message "Session does not exist. Initiate sesion cleanup on host %s" host)
        (dtache--cleanup-host-sessions host)
        nil))))

(defun dtache-session-exit-code-status (session)
  "Return status based on exit-code in SESSION."
  (if (null dtache-env)
      'unknown
    (with-temp-buffer
      (insert-file-contents (dtache--session-file session 'log))
      (goto-char (point-max))
      (if (string-match "Dtache session finished" (thing-at-point 'line t))
          'success
        'failure))))

(defun dtache-state-transition-notification (session)
  "Send a notification when SESSION transitions from active to inactive."
  (let ((status (pcase (dtache--session-status session)
                  ('success "Dtache finished")
                  ('failure "Dtache failed")) ))
    (message "%s: %s" status (dtache--session-command session))))

(defun dtache-view-dwim (session)
  "View SESSION in a do what I mean fashion."
  (cond ((eq 'success (dtache--session-status session))
         (dtache-open-output session))
        ((eq 'failure (dtache--session-status session))
         (dtache-post-compile-session session))
        ((eq 'unknown (dtache--session-status session))
         (dtache-open-output session))
        (t (message "Dtache session is in an unexpected state."))))

(defun dtache-get-sessions ()
  "Update and return sessions."
  (dtache--update-sessions)
  (dtache--db-get-sessions))

;;;;; Other

(cl-defgeneric dtache-dtach-command (entity &optional concat)
  "Return dtach command for ENTITY optionally CONCAT.")

(cl-defgeneric dtache-dtach-command ((command string) &optional concat)
  "Return dtach command for COMMAND.

Optionally CONCAT the command return command into a string."
  (dtache-dtach-command (dtache-create-session command) concat))

(cl-defgeneric dtache-dtach-command ((session dtache-session) &optional concat)
  "Return dtach command for SESSION.

Optionally CONCAT the command return command into a string."
  (with-connection-local-variables
   (let* ((dtache-session-mode (cond ((eq dtache-session-mode 'attach) 'attach)
                                     ((not (dtache--session-attachable session)) 'create)
                                     (t dtache-session-mode)))
          (socket (dtache--session-file session 'socket t))
          (dtach-arg (dtache--dtach-arg)))
     (setq dtache--buffer-session session)
     (if (eq dtache-session-mode 'attach)
         (if concat
             (mapconcat 'identity
                        `(,dtache-dtach-program
                          ,dtach-arg
                          ,socket)
                        " ")
           `(,dtach-arg ,socket))
       (if concat
           (mapconcat 'identity
                      `(,dtache-dtach-program
                        ,dtach-arg
                        ,socket "-z"
                        ,dtache-shell-program "-c"
                        ,(shell-quote-argument (dtache--dtache-command session)))
                      " ")
         `(,dtach-arg ,socket "-z"
                      ,dtache-shell-program "-c"
                      ,(dtache--dtache-command session)))))))

(defun dtache-attachable-command-p (command)
  "Return t if COMMAND is attachable."
  (if (thread-last dtache-nonattachable-commands
                   (seq-filter (lambda (regexp)
                                 (string-match-p regexp command)))
                   (length)
                   (= 0))
      t
    nil))

(defun dtache-metadata ()
  "Return a property list with metadata."
  (let ((metadata '()))
    (seq-doseq (annotator dtache-metadata-annotators-alist)
      (push `(,(car annotator) . ,(funcall (cdr annotator))) metadata))
    metadata))

(defun dtache-completing-read (sessions)
  "Select a session from SESSIONS through `completing-read'."
  (let* ((candidates (dtache-session-candidates sessions))
         (metadata `(metadata
                     (category . dtache)
                     (cycle-sort-function . identity)
                     (display-sort-function . identity)
                     (annotation-function . dtache-session-annotation)
                     (affixation-function .
                                          ,(lambda (cands)
                                             (seq-map (lambda (s)
                                                        `(,s nil ,(dtache-session-annotation s)))
                                                      cands)))))
         (collection (lambda (string predicate action)
                       (if (eq action 'metadata)
                           metadata
                         (complete-with-action action candidates string predicate))))
         (cand (completing-read "Select session: " collection nil t)))
    (dtache--decode-session cand)))

;;;; Support functions

;;;;; Session

(defun dtache--session-pid (session)
  "Return SESSION's pid."
  (let* ((socket
          (concat
           (dtache--session-directory session)
           (symbol-name (dtache--session-id session))
           ".socket"))
         (regexp (rx-to-string `(and "dtach " (or "-n " "-c ") ,socket)))
         (ps-args '("aux" "-w")))
    (with-temp-buffer
      (apply #'process-file `("ps" nil t nil ,@ps-args))
      (goto-char (point-min))
      (when (search-forward-regexp regexp nil t)
        (elt (split-string (thing-at-point 'line) " " t) 1)))))

(defun dtache--session-child-pids (pid)
  "Return a list of pids for all child processes including PID."
  (let ((pids `(,pid))
        (child-processes
         (split-string
          (shell-command-to-string (format "pgrep -P %s" pid))
          "\n" t)))
    (seq-do (lambda (pid)
              (push (dtache--session-child-pids pid) pids))
            child-processes)
    pids))

(defun dtache--session-truncate-command (session)
  "Return a truncated string representation of SESSION's command."
  (let ((command (dtache--session-command session)))
    (if (<= (length command) dtache-max-command-length)
        command
      (concat
       (substring command 0 (/ dtache-max-command-length 2))
       "..."
       (substring command (- (length command) (/ dtache-max-command-length 2)) (length command))))))

(defun dtache--determine-session-state (session)
  "Return t if SESSION is active."
  (if (file-exists-p
       (dtache--session-file session 'socket))
      'active
    'inactive))

(defun dtache--state-transition-p (session)
  "Return t if SESSION has transitioned from active to inactive."
  (and
   (eq 'active (dtache--session-state session))
   (eq 'inactive (dtache--determine-session-state session))))

(defun dtache--session-missing-p (session)
  "Return t if SESSION is missing."
  (not
   (file-exists-p
    (dtache--session-file session 'log))))

(defun dtache--session-header (session)
  "Return header for SESSION."
  (mapconcat
   #'identity
   `(,(format "Command: %s" (dtache--session-command session))
     ,(format "Working directory: %s" (dtache--working-dir-str session))
     ,(format "Host: %s" (dtache--session-host session))
     ,(format "Id: %s" (symbol-name (dtache--session-id session)))
     ,(format "Status: %s" (dtache--session-status session))
     ,(format "Metadata: %s" (dtache--metadata-str session))
     ,(format "Created at: %s" (dtache--creation-str session))
     ,(format "Duration: %s\n" (dtache--duration-str session))
     "")
   "\n"))

(defun dtache--session-timer-monitor (session)
  "Configure a timer to monitor SESSION activity.
The timer object is configured according to `dtache-timer-configuration'."
  (with-connection-local-variables
   (let* ((timer)
          (callback
           (lambda ()
             (when (dtache--state-transition-p session)
               (setf (dtache--session-duration session)
                     (dtache--determine-duration session t))
               (dtache--session-state-transition-update session)
               (cancel-timer timer)))))
     (setq timer
           (funcall (plist-get dtache-timer-configuration :function)
                    (plist-get dtache-timer-configuration :seconds)
                    (plist-get dtache-timer-configuration :repeat)
                    callback)))))

(defun dtache--session-filenotify-monitor (session)
  "Configure `filenotify' to monitor SESSION activity."
  (file-notify-add-watch
   (dtache--session-file session 'socket)
   '(change)
   (lambda (event)
     (pcase-let ((`(,_ ,action ,_) event))
       (when (eq action 'deleted)
         (setf (dtache--session-duration session)
               (dtache--determine-duration session))
         (dtache--session-state-transition-update session))))))

(defun dtache--session-deduplicate (sessions)
  "Make car of SESSIONS unique by adding an identifier to it."
  (let* ((ht (make-hash-table :test #'equal :size (length sessions)))
         (identifier-width 6)
         (reverse-sessions (seq-reverse sessions)))
    (dolist (session reverse-sessions)
      (if-let (count (gethash (car session) ht))
          (setcar session (format "%s%s" (car session)
                                  (truncate-string-to-width
                                   (propertize (format " (%s)" (puthash (car session) (1+ count) ht)) 'face 'dtache-identifier-face)
                                   identifier-width 0 ?\s)))
        (puthash (car session) 0 ht)
        (setcar session (format "%s%s" (car session) (make-string identifier-width ?\s)))))
    (seq-reverse reverse-sessions)))

(defun dtache--session-macos-monitor (session)
  "Configure a timer to monitor SESSION activity on macOS."
  (let ((dtache-timer-configuration
         '(:seconds 0.5 :repeat 0.5 :function run-with-idle-timer)))
    (dtache--session-timer-monitor session)))

(defun dtache--decode-session (item)
  "Return the session assicated with ITEM."
  (cdr (assoc item dtache--session-candidates)))

(defun dtache--update-sessions ()
  "Update `dtache' sessions.

Sessions running on  current host or localhost are updated."
  (let ((current-host (dtache--host)))
    (seq-do (lambda (it)
              (if (and (or (string= current-host (dtache--session-host it))
                           (string= "localhost" (dtache--session-host it)))
                       (or (eq 'active (dtache--session-state it))
                           (dtache--state-transition-p it)))
                  (dtache--update-session it)))
            (dtache--db-get-sessions))))

(defun dtache--update-session (session)
  "Update SESSION."
  (if (or (dtache--state-transition-p session)
          (dtache--session-missing-p session))
      (progn
        (setf (dtache--session-duration session)
              (dtache--determine-duration session t))
        (dtache--session-state-transition-update session))
    (setf (dtache--session-log-size session)
          (file-attribute-size (file-attributes
                                (dtache--session-file session 'log))))
    (dtache--db-update-entry session)))

(defun dtache--session-file (session file &optional local)
  "Return the full path to SESSION's FILE.

Optionally make the path LOCAL to host."
  (let* ((file-name
          (concat
           (symbol-name
            (dtache--session-id session))
           (pcase file
             ('socket ".socket")
             ('log ".log"))))
         (remote (file-remote-p (dtache--session-working-directory session)))
         (directory (concat
                     remote
                     (dtache--session-directory session))))
    (if (and local remote)
        (string-remove-prefix remote (expand-file-name file-name directory))
      (expand-file-name file-name directory))))

(defun dtache--cleanup-host-sessions (host)
  "Run cleanuup on HOST sessions."
  (thread-last (dtache--db-get-sessions)
               (seq-filter (lambda (it) (string= host (dtache--session-host it))))
               (seq-filter #'dtache--session-missing-p)
               (seq-do #'dtache--db-remove-entry)))

(defun dtache--session-output (session)
  "Return content of SESSION's output."
  (let* ((filename (dtache--session-file session 'log))
         (dtache-message (rx (regexp "\n?\nDtache session ") (or "finished" "exited"))))
    (with-temp-buffer
      (insert-file-contents filename)
      (goto-char (point-min))
      (let ((beginning (point))
            (end (if (search-forward-regexp dtache-message nil t)
                     (match-beginning 0)
                   (point-max))))
        (buffer-substring beginning end)))))

(defun dtache--create-session-directory ()
  "Create session directory if it doesn't exist."
  (let ((directory
         (concat
          (file-remote-p default-directory)
          dtache-session-directory)))
    (unless (file-exists-p directory)
      (make-directory directory t))))

(defun dtache--get-working-directory ()
  "Return an abreviated working directory path."
  (let* ((remote (file-remote-p default-directory))
         (full-home (if remote (expand-file-name remote) (expand-file-name "~")))
         (short-home (if remote (concat remote "~/") "~")))
    (replace-regexp-in-string full-home
                              short-home
                              (expand-file-name default-directory))))

(defun dtache--attach-session (session)
  "Attach to SESSION."
  (if (not (dtache--session-attachable session))
      (dtache-tail-output session)
    (if-let ((attach-fun (plist-get (dtache--session-action session) :attach)))
        (funcall attach-fun session)
      (dtache-tail-output session))))

(defun dtache--view-session (session)
  "View SESSION."
  (if-let ((view-fun (plist-get (dtache--session-action session) :view)))
      (funcall view-fun session)
    (dtache-view-dwim session)))

;;;;; Database

(defun dtache--db-initialize ()
  "Return all sessions stored in database."
  (let ((db (expand-file-name "dtache.db" dtache-db-directory)))
    (when (file-exists-p db)
      (with-temp-buffer
        (insert-file-contents db)
        (cl-assert (eq (point) (point-min)))
        (goto-char (point-min))
        (when (string= (dtache--db-session-version) dtache-session-version)
          (setq dtache--sessions
                (read (current-buffer))))))))

(defun dtache--db-session-version ()
  "Return `dtache-session-version' from database."
  (let ((header (thing-at-point 'line))
        (regexp (rx "Dtache Session Version: " (group (one-or-more (or digit punct))))))
    (string-match regexp header)
    (match-string 1 header)))

(defun dtache--db-insert-entry (session)
  "Insert SESSION into `dtache--sessions' and update database."
  (push `(,(dtache--session-id session) . ,session) dtache--sessions)
  (dtache--db-update-sessions))

(defun dtache--db-remove-entry (session)
  "Remove SESSION from `dtache--sessions', delete log and update database."
  (let ((log (dtache--session-file session 'log)))
    (when (file-exists-p log)
      (delete-file log)))
  (setq dtache--sessions
        (assq-delete-all (dtache--session-id session) dtache--sessions ))
  (dtache--db-update-sessions))

(defun dtache--db-update-entry (session &optional update)
  "Update SESSION in `dtache--sessions' optionally UPDATE database."
  (setf (alist-get (dtache--session-id session) dtache--sessions) session)
  (when update
    (dtache--db-update-sessions)))

(defun dtache--db-get-session (id)
  "Return session with ID."
  (alist-get id dtache--sessions))

(defun dtache--db-get-sessions ()
  "Return all sessions stored in the database."
  (seq-map #'cdr dtache--sessions))

(defun dtache--db-update-sessions ()
  "Write `dtache--sessions' to database."
  (let ((db (expand-file-name "dtache.db" dtache-db-directory)))
    (with-temp-file db
      (insert (format ";; Dtache Session Version: %s\n\n" dtache-session-version))
      (prin1 dtache--sessions (current-buffer)))))

;;;;; Other

(defun dtache--dtach-arg ()
  "Return dtach argument based on `dtache-session-mode'."
  (pcase dtache-session-mode
    ('create "-n")
    ('create-and-attach "-c")
    ('attach "-a")
    (_ (error "`dtache-session-mode' has an unknown value"))))

(defun dtache--session-state-transition-update (session)
  "Update SESSION due to state transition."
  (if (dtache--session-missing-p session)
      ;; Remove missing session
      (dtache--db-remove-entry session)

    ;; Update session
    (setf (dtache--session-log-size session)
          (file-attribute-size
           (file-attributes
            (dtache--session-file session 'log))))

    (setf (dtache--session-state session) 'inactive)

    ;; Update status
    (let ((status (or (plist-get (dtache--session-action session) :status)
                      #'dtache-session-exit-code-status)))
      (setf (dtache--session-status session) (funcall status session)))

    ;; Send notification
    (funcall dtache-notification-function session)

    ;; Update session in database
    (dtache--db-update-entry session t)

    ;; Execute callback
    (when-let ((callback (plist-get (dtache--session-action session) :callback)))
      (funcall callback session))))

(defun dtache--kill-processes (pid)
  "Kill PID and all of its children."
  (let ((child-processes
         (split-string
          (shell-command-to-string (format "pgrep -P %s" pid))
          "\n" t)))
    (seq-do (lambda (pid) (dtache--kill-processes pid)) child-processes)
    (apply #'process-file `("kill" nil nil nil ,pid))))

(defun dtache--dtache-command (session)
  "Return the dtache command for SESSION.

If SESSION is nonattachable fallback to a command that doesn't rely on tee."
  (let* ((log (dtache--session-file session 'log t))
         (redirect
          (if (dtache--session-attachable session)
              (format "2>&1 | tee %s" log)
            (format "&> %s" log)))
         (env (if dtache-env dtache-env (format "%s -c" dtache-shell-program)))
         (command
          (shell-quote-argument
           (dtache--session-command session))))
    (format "{ %s %s; } %s" env command redirect)))

(defun dtache--host ()
  "Return name of host."
  (or
   (file-remote-p default-directory 'host)
   "localhost"))

(defun dtache--determine-duration (session &optional approximate)
  "Return the time duration of the SESSION.

If APPROXIMATE, use latest modification time to deduce the duration.
Otherwise the current time is used."
  (if (not approximate)
      (- (time-to-seconds) (dtache--session-creation-time session))
    (- (time-to-seconds
        (file-attribute-modification-time
         (file-attributes
          (dtache--session-file session 'log))))
       (dtache--session-creation-time session))))

(defun dtache--create-id (command)
  "Return a hash identifier for COMMAND."
  (let ((current-time (current-time-string)))
    (secure-hash 'md5 (concat command current-time))))

(defun dtache--dtache-env-message-filter (str)
  "Remove `dtache-env' message in STR."
  (replace-regexp-in-string "\n?Dtache session.*\n?" "" str))

(defun dtache--dtach-eof-message-filter (str)
  "Remove `dtache--dtach-eof-message' in STR."
  (replace-regexp-in-string (format "\n?%s\^M\n" dtache--dtach-eof-message) "" str))

(defun dtache--dtach-detached-message-filter (str)
  "Remove `dtache--dtach-detached-message' in STR."
  (replace-regexp-in-string (format "\n?%s\n" dtache--dtach-detached-message) "" str))

(defun dtache--start-session-monitor (session)
  "Start to monitor SESSION activity."
  (let ((default-directory (dtache--session-working-directory session)))
    (if (and (not(file-remote-p default-directory))
             (eq system-type 'darwin))
        ;; macOS requires a timer based solution
        (dtache--session-macos-monitor session)
      (dtache--session-filenotify-monitor session))))

;;;;; UI

(defun dtache--metadata-str (session)
  "Return SESSION's metadata as a string."
  (string-join
   (thread-last (dtache--session-metadata session)
                (seq-filter (lambda (it) (cdr it)))
                (seq-map
                 (lambda (it)
                   (concat (symbol-name (car it)) ": " (cdr it)))))
   " "))

(defun dtache--duration-str (session)
  "Return SESSION's duration time."
  (let* ((time
          (round (if (eq 'active (dtache--session-state session))
                     (dtache--determine-duration session)
                   (dtache--session-duration session))))
         (hours (/ time 3600))
         (minutes (/ (mod time 3600) 60))
         (seconds (mod time 60)))
    (cond ((> time (* 60 60)) (format "%sh %sm %ss" hours minutes seconds))
          ((> time 60) (format "%sm %ss" minutes seconds))
          (t (format "%ss" seconds)))))

(defun dtache--creation-str (session)
  "Return SESSION's creation time."
  (format-time-string
   "%b %d %H:%M"
   (dtache--session-creation-time session)))

(defun dtache--size-str (session)
  "Return the size of SESSION's output."
  (file-size-human-readable
   (dtache--session-log-size session)))

(defun dtache--status-str (session)
  "Return string if SESSION has failed."
  (pcase (dtache--session-status session)
    ('failure "!")
    ('success " ")
    ('unknown " ")))

(defun dtache--state-str (session)
  "Return string based on SESSION state."
  (if (eq 'active (dtache--session-state session))
      "*"
    " "))

(defun dtache--working-dir-str (session)
  "Return working directory of SESSION."
  (let ((working-directory
         (dtache--session-working-directory session)))
    (if-let ((remote (file-remote-p working-directory)))
        (string-remove-prefix remote working-directory)
      working-directory)))

;;;; Minor modes

;;;###autoload
(define-minor-mode dtache-shell-mode
  "Integrate `dtache' in `shell-mode'."
  :lighter "dtache-shell"
  :keymap (let ((map (make-sparse-keymap)))
            map)
  (if dtache-shell-mode
      (progn
        (add-hook 'comint-preoutput-filter-functions #'dtache--dtache-env-message-filter 0 t)
        (add-hook 'comint-preoutput-filter-functions #'dtache--dtach-eof-message-filter 0 t))
    (remove-hook 'comint-preoutput-filter-functions #'dtache--dtache-env-message-filter t)
    (remove-hook 'comint-preoutput-filter-functions #'dtache--dtach-eof-message-filter t)))

;;;; Major modes

(defvar dtache-log-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `dtache-log-mode'.")

;;;###autoload
(define-derived-mode dtache-log-mode nil "Dtache Log"
  "Major mode for dtache logs."
  (read-only-mode t))

(defvar dtache-tail-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `dtache-tail-mode'.")

;;;###autoload
(define-derived-mode dtache-tail-mode auto-revert-tail-mode "Dtache Tail"
  "Major mode for tailing dtache logs."
  (setq-local auto-revert-interval dtache-tail-interval)
  (setq-local tramp-verbose 1)
  (setq-local auto-revert-remote-files t)
  (defvar revert-buffer-preserve-modes)
  (setq-local revert-buffer-preserve-modes nil)
  (auto-revert-set-timer)
  (setq-local auto-revert-verbose nil)
  (auto-revert-tail-mode)
  (read-only-mode t))

(provide 'dtache)

;;; dtache.el ends here
