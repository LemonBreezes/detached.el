;;; dtache-test.el --- Tests for dtache.el -*- lexical-binding: t; -*-

;; Copyright (C) 2020-2022  Niklas Eklund

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for `dtache'.

;;; Code:

;;;; Requirements

(require 'ert)
(require 'dtache)

;;;; Support

(defmacro dtache-test--with-temp-database (&rest body)
  "Initialize a dtache database and evaluate BODY."
  `(let* ((temp-directory (make-temp-file "dtache" t))
          (dtache-db-directory (expand-file-name "dtache.db" temp-directory))
          (dtache-log-directory (expand-file-name "sessions" temp-directory))
          (dtache--sessions)
          (dtache--sessions-initialized)
          (dtache--remote-session-timer))
     (unwind-protect
         (progn
           (dtache-setup)
           ,@body)
       (delete-directory temp-directory t))))

(cl-defun dtache-test--create-session (&key command host)
  "Create session with COMMAND running on HOST."
  (cl-letf* (((symbol-function #'dtache--host) (lambda () host))
             ((symbol-function #'dtache-metadata) (lambda () nil))
             (session (dtache-create-session command)))
    (dtache-test--change-session-state session 'activate)
    session))

(defun dtache-test--change-session-state (session state)
  "Set STATE of SESSION."
  (pcase state
    ('activate
     (dolist (type `(socket log))
       (with-temp-file (dtache--session-file session type))))
    ('deactivate
     (delete-file (dtache--session-file session 'socket)))
    ('kill
     (delete-file (dtache--session-file session 'socket))
     (delete-file (dtache--session-file session 'log)))))

;;;; Tests

(ert-deftest dtache-test-dtach-command ()
  (dtache-test--with-temp-database
   (cl-letf* ((dtach-program "dtach")
              (dtache-env "dtache-env")
              (dtache-shell-program "bash")
              (session (dtache-create-session "ls -la"))
              ((symbol-function #'dtache-create-session)
               (lambda (_)
                 session)))
     (let* ((dtache-session-mode 'create)
            (expected `("-c" ,(dtache--session-file session 'socket t)
                        "-z" ,dtache-shell-program
                        "-c"
                        ,(format "{ dtache-env ls\\ -la; } 2>&1 | tee %s"
                                 (dtache--session-file session 'log t))))
            (expected-concat (format "%s -c %s -z %s -c %s"
                                     dtach-program
                                     (dtache--session-file session 'socket t)
                                     dtache-shell-program
                                     (shell-quote-argument
                                      (format "{ dtache-env ls\\ -la; } 2>&1 | tee %s"
                                              (dtache--session-file session 'log t))))))
       (should (equal expected (dtache-dtach-command session)))
       (should (equal expected-concat (dtache-dtach-command session t))))
     (let* ((dtache-session-mode 'attach)
            (expected `("-a" ,(dtache--session-file session 'socket t)))
            (expected-concat (format "%s -a %s"
                                     dtach-program
                                     (dtache--session-file session 'socket t))))
       (should (equal expected (dtache-dtach-command session)))
       (should (equal expected-concat (dtache-dtach-command session t)))))))

(ert-deftest dtache-test-metadata ()
  ;; No annotators
  (let ((dtache-metadata-annotators-alist '()))
    (should (not (dtache-metadata))))

  ;; Two annotators
  (let ((dtache-metadata-annotators-alist
         '((git-branch . (lambda () "foo"))
           (username . (lambda () "bar"))))
        (expected '((username . "bar")
                    (git-branch . "foo"))))
    (should (equal (dtache-metadata) expected))))

(ert-deftest dtache-test-session-file ()
  ;; Local files
  (cl-letf* (((symbol-function #'expand-file-name) (lambda (file directory) (concat directory file)))
             ((symbol-function #'file-remote-p) (lambda (_directory) nil))
             (session (dtache--session-create :id 's12345 :log-directory "/home/user/tmp/")))
    (should (string= "/home/user/tmp/s12345.log" (dtache--session-file session 'log)))
    (should (string= "/home/user/tmp/s12345.socket" (dtache--session-file session 'socket))))

  ;; Remote files
  (cl-letf* (((symbol-function #'expand-file-name) (lambda (file directory) (concat directory file)))
             ((symbol-function #'file-remote-p) (lambda (_directory) "/ssh:foo:"))
             (session (dtache--session-create :id 's12345 :log-directory "/home/user/tmp/")))
    (should (string= "/ssh:foo:/home/user/tmp/s12345.log" (dtache--session-file session 'log)))
    (should (string= "/ssh:foo:/home/user/tmp/s12345.socket" (dtache--session-file session 'socket)))))

(ert-deftest dtache-test-session-truncate-command ()
  (let ((dtache-max-command-length 7))
    (dtache--session-truncate-command
     (dtache--session-create :command "12345678"))
    (should (string= "123...678"
                     (dtache--session-truncate-command
                      (dtache--session-create :command "12345678")))))
  (let ((dtache-max-command-length 2))
    (dtache--session-truncate-command
                      (dtache--session-create :command "12345678"))
    (should (string= "1...8"
                     (dtache--session-truncate-command
                      (dtache--session-create :command "12345678"))))))

(ert-deftest dtache-test-host ()
  (should (string= "localhost" (dtache--host)))
  (let ((default-directory "/ssh:remotehost:/home/user/git"))
    (should (string= "remotehost" (dtache--host)))))

(ert-deftest dtache-test-session-active-p ()
  (dtache-test--with-temp-database
   (let ((session (dtache-test--create-session :command "foo" :host "localhost")))
     (should (dtache--session-active-p session))
     (dtache-test--change-session-state session 'deactivate)
     (should (not (dtache--session-active-p session))))))

(ert-deftest dtache-test-session-dead-p ()
  (dtache-test--with-temp-database
   (let ((session (dtache-test--create-session :command "foo" :host "localhost")))
     (should (not (dtache--session-missing-p session)))
     (dtache-test--change-session-state session 'deactivate)
     (should (not (dtache--session-missing-p session)))
     (dtache-test--change-session-state session 'kill)
     (should (dtache--session-missing-p session)))))

(ert-deftest dtache-test-cleanup-host-sessions ()
  (dtache-test--with-temp-database
   (cl-letf* ((session1 (dtache-test--create-session :command "foo" :host "remotehost"))
              (session2 (dtache-test--create-session :command "bar" :host "localhost"))
              (session3 (dtache-test--create-session :command "baz" :host "localhost"))
              (host "localhost")
              ((symbol-function #'dtache--host) (lambda () host)))
     ;; One inactive, one missing, one active
     (dtache-test--change-session-state session1 'deactivate)
     (dtache-test--change-session-state session2 'kill)
     (dtache--cleanup-host-sessions host)
     (should (seq-set-equal-p
              (dtache--db-get-sessions)
              `(,session1 ,session3))))))

;;;;; Database

(ert-deftest dtache-test-db-insert-session ()
  (dtache-test--with-temp-database
   (let* ((session (dtache-test--create-session :command "foo" :host "localhost")))
     (should (equal (dtache--db-get-sessions) `(,session))))))

(ert-deftest dtache-test-db-remove-session ()
  (dtache-test--with-temp-database
   (let* ((host "localhost")
          (session1 (dtache-test--create-session :command "foo" :host host))
          (session2 (dtache-test--create-session :command "bar" :host host)))
     (should (seq-set-equal-p `(,session1 ,session2) (dtache--db-get-sessions)))
     (dtache--db-remove-entry session1)
     (should (seq-set-equal-p `(,session2) (dtache--db-get-sessions))))))

(ert-deftest dtache-test-db-update-session ()
  (dtache-test--with-temp-database
   (let* ((session (dtache-test--create-session :command "foo" :host "localhost"))
          (id (dtache--session-id session))
          (copy))
     (setq copy (copy-dtache-session session))
     (setf (dtache--session-active copy) nil)
     (should (not (equal copy (dtache--db-get-session id))))
     (dtache--db-update-entry copy t)
     (should (equal copy (car (dtache--db-get-sessions)))))))

(ert-deftest dtache-test-magic-command ()
  (let ((normal-session (dtache--session-create :log-directory "/tmp/dtache/"
                                                :working-directory "/home/user/"
                                                :command "ls -la"
                                                :id 'foo123))
        (redirect-session (dtache--session-create :log-directory "/tmp/dtache/"
                                                :working-directory "/home/user/"
                                                :command "ls -la"
                                                :redirect-only t
                                                :id 'foo123)))
    ;; With dtache-env
    (let ((dtache-env "dtache-env"))
      (should (string= "{ dtache-env ls\\ -la; } 2>&1 | tee /tmp/dtache/foo123.log"
                       (dtache--magic-command normal-session)))
      (should (string= "{ dtache-env ls\\ -la; } &> /tmp/dtache/foo123.log"
                       (dtache--magic-command redirect-session))))

    ;; Without dtache-env
    (let ((dtache-env nil)
          (dtache-shell-program "bash"))
      (should (string= "{ bash -c ls\\ -la; } 2>&1 | tee /tmp/dtache/foo123.log"
                       (dtache--magic-command normal-session)))
      (should (string= "{ bash -c ls\\ -la; } &> /tmp/dtache/foo123.log"
                       (dtache--magic-command redirect-session))))))

(ert-deftest dtache-test-redirect-only-p ()
  (let ((dtache-redirect-only-regexps '("ls")))
    (should (not (dtache-redirect-only-p "cd")))
    (should (dtache-redirect-only-p "ls -la"))))

(ert-deftest dtache-test-session-pid ()
  (cl-letf* (((symbol-function #'process-file) (lambda (_program _infile _buffer _display &rest _args)
                                                 (insert "\"USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND\nuser    6699  0.0  0.0   4752  2304 ?        Ss   13:06   0:00 dtach -n /tmp/foo.socket\nuser    6698  0.0  0.0   4752  2304 ?        Ss   13:07   0:00 dtach -c /tmp/bar.socket\n")))

             (session1 (dtache--session-create :id 'foo :log-directory "/tmp/"))
             (session2 (dtache--session-create :id 'bar :log-directory "/tmp/"))
             (session3 (dtache--session-create :id 'baz :log-directory "/tmp/")))
    (should (string= "6699" (dtache--session-pid session1)))
    (should (string= "6698" (dtache--session-pid session2)))
    (should (not (dtache--session-pid session3)))))

;;;;; String representations

(ert-deftest dtache-test-duration-str ()
  (should (string= "1s" (dtache--duration-str (dtache--session-create :duration 1))))
  (should (string= "1m 1s" (dtache--duration-str (dtache--session-create :duration 61))))
  (should (string= "1h 1m 1s" (dtache--duration-str (dtache--session-create :duration 3661)))))

(ert-deftest dtache-test-creation-str ()
  ;; Make sure to set the TIMEZONE before executing the test to avoid
  ;; differences between machines
  (cl-letf (((getenv "TZ") "UTC0"))
    (should (string= "May 08 08:49" (dtache--creation-str (dtache--session-create :creation-time 1620463748.7636228))))))

(ert-deftest dtache-test-size-str ()
  (should (string= "100" (dtache--size-str (dtache--session-create :output-size 100))))
  (should (string= "1k" (dtache--size-str (dtache--session-create :output-size 1024)))))

(ert-deftest dtache-test-status-str ()
  (should (string= "!" (dtache--status-str (dtache--session-create :status 'failure))))
  (should (string= " " (dtache--status-str (dtache--session-create :status 'success))))
  (should (string= " " (dtache--status-str (dtache--session-create :status 'unknown)))))

(ert-deftest dtache-test-active-str ()
  (should (string= "*" (dtache--active-str (dtache--session-create :active t))))
  (should (string= " " (dtache--active-str (dtache--session-create :active nil)))))

(ert-deftest dtache-test-working-dir-str ()
  (should
   (string= "/home/user/repo"
            (dtache--working-dir-str
             (dtache--session-create :working-directory "/ssh:remote:/home/user/repo"))))
  (should
   (string= "~/repo"
            (dtache--working-dir-str
             (dtache--session-create :working-directory "~/repo")))))

;;;;; Output filters

(ert-deftest dtache-test-dtach-eof-message-filter ()
  (let ((str "
[EOF - dtach terminating]
user@machine "))
    (should (string= "user@machine " (dtache--dtach-eof-message-filter str)))))

(ert-deftest dtache-test-dtach-detached-message-filter ()
  (let ((str "
[detached]
user@machine "))
    (should (string= "user@machine " (dtache--dtach-detached-message-filter str)))))

(ert-deftest dtache-test-dtache-env-message-filter ()
  (let ((str "output\n\nDtache session exited abnormally with code 127"))
    (should (string= "output\n" (dtache--dtache-env-message-filter str))))
  (let ((str "output\n\nDtache session finished"))
    (should (string= "output\n" (dtache--dtache-env-message-filter str)))))

(provide 'dtache-test)

;;; dtache-test.el ends here
