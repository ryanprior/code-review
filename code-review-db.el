;;; code-review-db.el --- Manage code review database -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Wanderson Ferreira
;;
;; Author: Wanderson Ferreira <https://github.com/wandersoncferreira>
;; Maintainer: Wanderson Ferreira <wand@hey.com>
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Description
;;
;;; Code:

(require 'closql)
(require 'eieio)
(require 'uuidgen)

(defcustom code-review-database-connector 'sqlite
  "The database connector."
  :group 'code-review)

(defcustom code-review-database-file
  (expand-file-name "code-review-database.sqlite" user-emacs-directory)
  "The file used to store the code-review database."
  :group 'code-review
  :type 'file)

(declare-function code-review-database--eieio-childp "code-review-db.el" (obj) t)

(defclass code-review-buffer (closql-object)
  ((closql-table        :initform 'buffer)
   (closql-primary-key  :initform 'id)
   (closql-foreign-key  :initform 'pullreq)
   (closql-class-prefix :initform "code-review-")
   (id                  :initarg :id)
   (pullreq             :initarg :pullreq)
   (raw-text            :initform nil)
   (paths               :closql-class code-review-path)))

(defclass code-review-path (closql-object)
  ((closql-table        :initform 'path)
   (closql-primary-key  :initform 'id)
   (closql-foreign-key  :initform 'buffer)
   (closql-class-prefix :initform "code-review-")
   (id                  :initarg :id)
   (name                :initarg :name)
   (head-pos            :initform nil)
   (buffer              :initarg :buffer)
   (at-pos-p            :initarg :at-pos-p)
   (comments            :closql-class code-review-comment)))

(defclass code-review-comment (closql-object)
  ((closql-table        :initform 'comment)
   (closql-primary-key  :initform 'id)
   (closql-foreign-key  :initform 'path)
   (closql-class-prefix :initform "code-review-")
   (id                  :initarg :id)
   (path                :initarg :path)
   (loc-written         :initform nil)
   (identifiers         :initarg :identifiers)))

(defclass code-review-pullreq (closql-object)
  ((closql-table        :initform 'pullreq)
   (closql-primary-key  :initform 'id)
   (closql-class-prefix :initform "code-review-")
   (closql-order-by     :initform [(desc number)])
   (id                  :initarg :id)
   (raw-infos           :initform nil)
   (raw-diff            :initform nil)
   (raw-comments        :initform nil)
   (owner               :initarg :owner)
   (repo                :initarg :repo)
   (number              :initarg :number)
   (host                :initform nil)
   (sha                 :initform nil)
   (feedback            :initform nil)
   (state               :initform nil)
   (replies             :initform nil)
   (review              :initform nil)
   (buffer              :closql-class code-review-buffer))
  :abstract t)

(defclass code-review-database (emacsql-sqlite-connection closql-database)
  ((object-class :initform 'code-review-pullreq)))

(defconst code-review--db-version 7)

(defconst code-review-db--sqlite-available-p
  (with-demoted-errors "Code Review initialization: %S"
    (emacsql-sqlite-ensure-binary)
    t))

;; (setq code-review--db-connection nil)
(defvar code-review--db-connection nil
  "The EmacSQL database connection.")

(defun code-review-db ()
  "Start connection."
  (unless (and code-review--db-connection (emacsql-live-p code-review--db-connection))
    (make-directory (file-name-directory code-review-database-file) t)
    (closql-db 'code-review-database 'code-review--db-connection
               code-review-database-file t))
  code-review--db-connection)

;;; Api

(defun code-review-sql (sql &rest args)
  (if (stringp sql)
      (emacsql (code-review-db) (apply #'format sql args))
    (apply #'emacsql (code-review-db) sql args)))

;;; Schema

(defconst code-review--db-table-schema
  '((pullreq
     [(class :not-null)
      (id :not-null :primary-key)
      raw-infos
      raw-diff
      raw-comments
      host
      sha
      owner
      repo
      number
      feedback
      replies
      review
      state
      callback
      (buffer :default eieio-unbound)])

    (buffer
     [(class :not-null)
      (id :not-null :primary-key)
      pullreq
      raw-text
      (path :default eieio-unbound)]
     (:foreign-key
      [pullreq] :references pullreq [id]
      :on-delete :cascade))

    (path
     [(class :not-null)
      (id :not-null :primary-key)
      name
      head-pos
      buffer
      at-pos-p
      (comment :default eieio-unbound)]
     (:foreign-key
      [buffer] :references buffer [id]
      :on-delete :cascade))

    (comment
     [(class :not-null)
      (id :not-null :primary-key)
      path
      loc-written
      identifiers]
     (:foreign-key
      [path] :references path [id]
      :on-delete :cascade))))

(cl-defmethod closql--db-init ((db code-review-database))
  (emacsql-with-transaction db
    (pcase-dolist (`(,table . ,schema) code-review--db-table-schema)
      (emacsql db [:create-table $i1 $S2] table schema))
    (closql--db-set-version db code-review--db-version)))

;; Helper

(defun code-review-db-update (obj)
  "Update whole OBJ in datatabase."
  (closql-insert (code-review-db) obj t))

;;; Domain

;; Simplified getters

(defun code-review-db-get-pullreq (id)
  "Get pullreq obj from ID."
  (closql-get (code-review-db) id 'code-review-pullreq))

(defun code-review-db-get-buffer (id)
  "Get buffer obj from ID."
  (closql-get (code-review-db) id 'code-review-buffer))

(defun code-review-db-get-path (id)
  "Get path obj from ID."
  (closql-get (code-review-db) id 'code-review-path))

(defun code-review-db-get-buffer-paths (buffer-id)
  "Get paths from BUFFER-ID."
  (let* ((buffers (code-review-db-get-buffer buffer-id))
         (buffer
          (if (eieio-object-p buffers)
              buffers
            (-first-item buffers))))
    (oref buffer paths)))

(defun code-review-db-get-comment (id)
  "Get comment obj from ID."
  (closql-get (code-review-db) id 'code-review-comment))

(defun code-review-db-get-curr-path-comment (id)
  "Get the comment obj for the current path in the pullreq ID."
  (let ((path (code-review-db--curr-path id)))
    (-first-item (oref path comments))))

(defun code-review-db-get-curr-head-pos (id)
  "Get the head-pos value for the current path in the pullreq ID."
  (let ((path (code-review-db--curr-path id)))
    (oref path head-pos)))

;; ...

(defun code-review-db--pullreq-create (obj)
  "Create a pullreq db object from OBJ."
  (let* ((pr-id (uuidgen-4)))
    (oset obj id pr-id)
    (closql-insert (code-review-db) obj t)))

(defun code-review-db-get-pr-alist (id)
  "Get pr-alist from ID."
  (let ((pr (code-review-db-get-pullreq id)))
    (a-alist 'num (oref pr number)
             'owner (oref pr owner)
             'repo (oref pr repo)
             'sha (oref pr sha))))

(defun code-review-db--pullreq-sha-update (id sha-value)
  "Update pullreq obj of ID with value SHA-VALUE."
  (let ((pr (code-review-db-get-pullreq id)))
    (oset pr sha sha-value)
    (closql-insert (code-review-db) pr t)))

(defun code-review-db--pullreq-raw-infos-update (pullreq infos)
  "Save INFOS to the PULLREQ entity."
  (oset pullreq raw-infos infos)
  (oset pullreq sha (a-get infos (list 'headRef 'target 'oid)))
  (oset pullreq raw-comments (a-get-in infos (list 'reviews 'nodes)))
  (closql-insert (code-review-db) pullreq t))

(defun code-review-db--pullreq-raw-diff-update (pullreq diff)
  "Save DIFF to the PULLREQ entity."
  (oset pullreq raw-diff diff)
  (closql-insert (code-review-db) pullreq t))

(defun code-review-db--pullreq-raw-infos (id)
  "Get raw infos alist from ID."
  (oref (code-review-db-get-pullreq id) raw-infos))

(defun code-review-db--pullreq-raw-comments (id)
  "Get raw comments alist from ID."
  (oref (code-review-db-get-pullreq id) raw-comments))

(defun code-review-db--pullreq-raw-diff (id)
  "Get raw diff alist from ID."
  (oref (code-review-db-get-pullreq id) raw-diff))

(defun code-review-db--pullreq-raw-comments-update (id comment)
  "Add COMMENT to the pullreq ID."
  (let* ((pr (code-review-db-get-pullreq id))
         (raw-comments (oref pr raw-comments)))
    (oset pr raw-comments (cons comment raw-comments))
    (closql-insert (code-review-db) pr t)))

;;;

(defun code-review-db--curr-path-update (id curr-path)
  "Update pullreq (ID) with CURR-PATH."
  (when id
    (let* ((pr (code-review-db-get-pullreq id))
           (buff (oref pr buffer))
           (buf (if (eieio-object-p buff) buff (-first-item buff)))
           (pr-id (oref pr id))
           (path-id (uuidgen-4))
           (db (code-review-db)))
      (if (not buf)
          (let* ((buf (code-review-buffer :id pr-id :pullreq pr-id))
                 (path (code-review-path :id path-id
                                         :buffer pr-id
                                         :name curr-path
                                         :at-pos-p t)))
            (emacsql-with-transaction db
              (closql-insert db buf t)
              (closql-insert db path t)))
        (let* ((paths (oref buf paths)))
          (emacsql-with-transaction db
          ;;; disable all previous ones
            (-map
             (lambda (path)
               (oset path at-pos-p nil)
               (closql-insert db path t))
             paths)
            ;; save new one
            (closql-insert db (code-review-path
                               :id path-id
                               :buffer (oref buf id)
                               :name curr-path
                               :at-pos-p t)
                           t)))))))

(defun code-review-db--curr-path-head-pos-update (id curr-path hunk-head-pos)
  "Update pullreq (ID) on CURR-PATH using HUNK-HEAD-POS."
  (let* ((pr (code-review-db-get-pullreq id))
         (buff (oref pr buffer))
         (buf (if (eieio-object-p buff) buff (-first-item buff)))
         (paths (oref buf paths)))
    (dolist (p paths)
      (when (string-equal (oref p name) curr-path)
        (oset p head-pos hunk-head-pos)
        (closql-insert (code-review-db) p t)))))

(defun code-review-db--head-pos (id path)
  "Get the first hunk position given a ID and PATH."
  (let* ((pr (code-review-db-get-pullreq id))
         (buff (oref pr buffer))
         (buf (if (eieio-object-p buff) buff (-first-item buff)))
         (paths (oref buf paths))
         (res
          (->> paths
               (-filter
                (lambda (p)
                  (string-equal (oref p name) path)))
               (-first-item))))
    (oref res head-pos)))

(defun code-review-db--curr-path-comment-count-update (id count)
  "Update pullreq (ID) on CURR-PATH using COUNT."
  (let* ((path (code-review-db--curr-path id))
         (comments (oref path comments))
         (comment (if (eieio-object-p comments) comments (-first-item comments))))
    (oset comment loc-written (+ (or (oref comment loc-written) 0) count))
    (closql-insert (code-review-db) comment t)))


;;; Accessor Functions

(defun code-review-db--curr-path (id)
  "Get the latest activated patch for the current pullreq obj ID."
  (let* ((pr (code-review-db-get-pullreq id))
         (buff (oref pr buffer))
         (buf (if (eieio-object-p buff) buff (-first-item buff))))
    (->> (oref buf paths)
         (-filter (lambda (p) (oref p at-pos-p)))
         (-first-item))))

(defun code-review-db--curr-path-name (id)
  "Get the latest activated patch for the current pullreq obj ID."
  (let* ((path (code-review-db--curr-path id)))
    (oref path name)))

;;;

(defun code-review-db--curr-path-comment-written-update (id identifier)
  "Update pullreq (ID) on curr path using IDENTIFIER."
  (let* ((path (code-review-db--curr-path id))
         (comment (-first-item (oref path comments))))
    (if (not comment)
        (let ((c (code-review-comment :id (oref path id)
                                      :path (oref path id)
                                      :identifiers (list identifier))))
          (closql-insert (code-review-db) c t))
      (progn
        (oset comment identifiers (cons identifier
                                        (oref comment identifiers)))
        (closql-insert (code-review-db) comment t)))))

;; comments

(defun code-review-db--comment-already-written? (id identifier)
  "Verify if comment from pullreq ID with IDENTIFIER was already marked as written."
  (let* ((buffers (code-review-db-get-buffer id))
         (buffer (if (eieio-object-p buffers) buffers (-first-item buffers)))
         (paths (oref buffer paths)))
    (-reduce-from
     (lambda (written? path)
       (let* ((comments (oref path comments))
              (comment (if (eieio-object-p comments) comments (-first-item comments))))
         (when comment
           (if written?
               written?
             (-contains-p (oref comment identifiers) identifier)))))
     nil
     paths)))

(defun code-review-db-get-comment-written-pos (id)
  "Get loc-written value for comment ID."
  (let ((comment (code-review-db-get-curr-path-comment id)))
    (if (not comment)
        0
      (oref comment loc-written))))

(provide 'code-review-db)
;;; code-review-db.el ends here
