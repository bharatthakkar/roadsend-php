;; ***** BEGIN LICENSE BLOCK *****
;; Roadsend PHP Compiler
;; Copyright (C) 2007 Roadsend, Inc.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA
;; ***** END LICENSE BLOCK *****


;;;; Generate Scheme code from a PHP AST
(module show-copies
   (include "php-runtime.sch")
   (library php-runtime)
   (library profiler)
   (import (ast "ast.scm")
	   (declare "declare.scm") )
   (export
    (generic show-copies node)) )


;XXX these global variables will need to be unified with the
;runtime variables of interpreted code somehow

(define *current-block* 'unset)


;unlike in evaluate.scm, this just contains the names of the exit functions
(define *break-stack* '())

;and this the names of the continue functions
(define *continue-stack* '())

(define *constant-bindings* '())

;for parent static method invocations -- they don't know who their daddy is.
(define *current-parent-class-name* #f)


;for method-decl stack trace entries
(define *current-class-name* #f)

;collect the actual code for the functions
(define *functions* '())

;code for constant definitions and classes
;(define *classes-and-constants* '())

;the name of the current environment for looking up variable variables
(define *current-var-var-env* #f)

(define *required-asts* '())
(define *exports* '())

(define *runtime-function-sigs* '())

(define *file-were-compiling* "")


;;;; show-copies
(define-generic (show-copies node)
   (if (list? node)
       (let ((node (filter (lambda (n) (not (nop? n))) node)))
	  (cons 'begin
		(map show-copies node)))
       (error 'show-copies (with-output-to-string
				(lambda ()
				   (print "show-copies: Don't know what to do with node: " node ", see?")))
	      #t)))


(define-method (show-copies node::php-ast)
   (set! *functions* '())
   (set! *constant-bindings* '())
   (set! *exports* '())
   (set! *runtime-function-sigs* '())
   (set! *current-ast* node)
   
   (dynamically-bind (*current-block* node)
      (dynamically-bind (*current-var-var-env* '*current-variable-environment*) ;'*global-env*)
	 ;;use *file-were-compiling* instead of the locations in the ast
	 ;;because it's been canonicalized some by driver.scm
	 (dynamically-bind (*file-were-compiling* (php-ast-real-filename node))
	    (let ((global-code (cdr ;strip off the 'begin
				;remove the nops from function decls et al.
				(filter (lambda (a) (not (nop? a)))
					(show-copies (php-ast-nodes node))))))
	       (values
		(fixup-onums
		 (cons
		  ;the function containing the global code
		  `(lambda (argv)
		      
		      (set! *PHP-FILE* ,*file-were-compiling*)
		      
		      
		      ,@(profile-wrap (string->symbol *file-were-compiling*)
				      `((bind-exit (return)
					   (let ,(global-bindings)
					      #t ;so it's never empty
					      ,@*runtime-function-sigs*
					      ,@global-code)))) )
		  ;the other functions (class definition is in here too, and is dependent on order)
		  (reverse *functions*)))
		*required-asts*
		*exports*))))))


(define (fixup-onums code)
   "For each onum found, replace it with a symbol bound to an appropriate
onum.  Append the bindings for the new symbols and code."
   (letrec ((onums '())
	    (onum-replace
	     (lambda (code)
		(if (php-number? code)
		    (cond
		       ((= 0 (onum-compare code *zero*))
			'*zero*)
		       ((= 0 (onum-compare code *one*))
			'*one*)
		       (else 
			(let ((the-num (gensym 'num)))
			   (pushf `(define ,the-num (convert-to-number ,(if (onum-long? code)
									    (onum->elong code)
									    (onum->float code))))
				  onums)
			   the-num)))
		    (if (pair? code)
			(cons (onum-replace (car code))
			      (onum-replace (cdr code)))
			code)))))
      (let ((new-code (onum-replace code)))
	 ;the car of the code is treated specially by driver.scm -- the global function
	 ;the constants have to be placed before their uses in the case of
	 ;e.g. static variables in php functions.
	 (cons (car new-code) (append onums (cdr new-code))))))

(define-method (show-copies node::function-invoke)
    (with-access::function-invoke node (location name arglist)
       `(begin
	   ;;The *PHP-FILE* sets around function-invoke have to be there,
	   ;;because *PHP-FILE* is used to resolve include file paths, and
	   ;;function-invoke generates the code for include() and friends.
	   ;;(They're builtins).
	   (set! *PHP-FILE* ,*file-were-compiling*)
	   (set! *PHP-LINE* ,(car location))
	   ,(let ((retval (gensym 'retval)))
	       `(let ((,retval 
		       ,(if (ast-node? name)
			    `(php-funcall ,(get-value name)
					  ,@(map get-location arglist))
			    (let* ((canonical-name (function-name-canonicalize name))
				   (sig (or (get-php-function-sig canonical-name)
					    (get-library-include canonical-name #f)))
				   (arglist-len (length arglist)))
;			       (fprint (current-error-port) "looked up: " canonical-name)
			       ;(fprint (current-error-port) "canon name is " canonical-name " from name " name)
			       (if sig
				   (try
				    (begin
				       (php-check-arity sig name arglist-len)
				       (let ((function-ast (hashtable-get *function->ast-table* canonical-name)))
					  (when function-ast
					     (pushf function-ast *required-asts*)))
				       `(,canonical-name
					 ,@(let ((total-args (if (sig-var-arity? sig)
								 arglist-len
								 (sig-length sig))))
					      (let loop ((i 0)
							 (args '()))
						 (if (< i total-args)
						     (loop (+ i 1)
							   (cons (pass-argument (if (< i arglist-len)
										    (list-ref arglist i)
										    #f)
										(sig-ref sig i))
								 args))
						     (reverse args))))))
				    (lambda (e p m o)
				       (php-error/loc node m)
				       (e #t)))
				    (begin
				       ;;disable these for now, since they are usually meaningless --tpd
; 				      (warning/loc node
; 						   (format "show-copies-function-invoke: undefined function ~A"
; 							   name))
				      `(php-funcall ',name
						    ,@(map get-location arglist))))))))
		   (set! *PHP-FILE* ,*file-were-compiling*)
		   (set! *PHP-LINE* ,(car location))
		   ,retval)))))


(define-method (show-copies node::nop)
   '(begin ) )

;;We need to force the hashtable to be copied, so set this to true if
;;you're looking up for the purpose of mutating something contained
;;in the hashtable.  Otherwise the hashtable's contents will be changed
;;without any pending copies being forced through.
(define *hash-lookup-writable* #f)

(define-method (show-copies node::hash-lookup)
   (with-access::hash-lookup node (hash key)
      (let ((the-key (if (eqv? key :next)
			 :next
			 (get-value key))))
  	 (if *hash-lookup-writable*
	     (if (is-hash? hash)
		 `(php-hash-lookup ,(get-value hash) ,the-key)
		 `(%general-lookup ,(get-value hash) ,the-key))
	     (if (is-hash? hash)
		 `(php-hash-lookup-honestly-just-for-reading ,(get-value hash) ,the-key)
		 `(%general-lookup-honestly-just-for-reading ,(get-value hash) ,the-key))))))


(define-method (show-copies node::literal-array)
   (with-access::literal-array node (array-contents)
      (let ((new-hash (gensym 'newhash)))
	 `(let ((,new-hash (make-php-hash)))
	     ,@(map
		(lambda (a)
		   (with-access::array-entry a (key value ref?)
		      `(php-hash-insert! ,new-hash
					 ,(if (eqv? key :next)
					      ':next
					      (get-value key))
					 ,(if ref?
					      (get-location value)
					      (get-value value)))))
		array-contents)
	     ,new-hash))))

(define-method (show-copies node::postcrement)
   (with-access::postcrement node (crement lval)
      (let ((old (gensym 'old)))
	 `(let ((,old ,(get-value lval)))
	     ,(update-value lval
			    (if (is-numeric? lval)
				(ecase crement
				   ((--) `(--/num ,old))
				   ((++) `(++/num ,old)))
				(ecase crement
				   ((--) `(-- ,old))
				   ((++) `(++ ,old)))))
	     ,old))))


(define-method (show-copies node::precrement)
   (with-access::precrement node (crement lval)
      (update-value lval
		    (if (is-numeric? lval)
			(ecase crement
			    ((--) `(--/num ,(get-value lval)))
			    ((++) `(++/num ,(get-value lval))))
			(ecase crement
			   ((--) `(-- ,(get-value lval)))
			   ((++) `(++ ,(get-value lval))))))))



(define-method (show-copies node::arithmetic-unop)
   (with-access::arithmetic-unop node (op a)
      (let ((a-val (get-value a)))
      (cond
	 ((compile-time-constant? a-val)
	  (ecase op
	     ((php-+) a-val)
	     ((php--) (php-- *zero* a-val))))
	 ((is-numeric? a)
	  (ecase op
	     ((php-+) `,a-val)
	     ((php--) `(php--/num *zero* ,a-val))))
	  (else
	   (ecase op
	      ((php-+) `,a-val)
	      ((php--) `(php-- *zero* ,a-val))))))))


(define-method (show-copies node::assigning-arithmetic-op)
   (with-access::assigning-arithmetic-op node (op lval rval)
      (let ((a (get-value lval))
	    (b (get-value rval)))
	 (update-value lval
		       (if (and (is-numeric? lval)
				(is-numeric? rval))
			   (ecase op
			      ((php-+) `(php-+/num ,a ,b))
			      ((php--) `(php--/num ,a ,b))
			      ((php-*) `(php-*-/num ,a ,b))
			      ((php-/) `(php-//num ,a ,b))
			      ((php-%) `(php-% ,a ,b)) ;xxx zoot!
			      ((bitwise-shift-left) `(bitwise-shift-left ,a ,b))
			      ((bitwise-shift-right) `(bitwise-shift-right ,a ,b))
			      ((bitwise-not) `(bitwise-not ,b))
			      ((bitwise-or) `(bitwise-or ,a ,b))
			      ((bitwise-xor) `(bitwise-xor ,a ,b))
			      ((bitwise-and) `(bitwise-and ,a ,b)))
			   (ecase op
			      ((php-+) `(php-+ ,a ,b))
			      ((php--) `(php-- ,a ,b))
			      ((php-*) `(php-* ,a ,b))
			      ((php-/) `(php-/ ,a ,b))
			      ((php-%) `(php-% ,a ,b))
			      ((bitwise-shift-left) `(bitwise-shift-left ,a ,b))
			      ((bitwise-shift-right) `(bitwise-shift-right ,a ,b))
			      ((bitwise-not) `(bitwise-not ,b))
			      ((bitwise-or) `(bitwise-or ,a ,b))
			      ((bitwise-xor) `(bitwise-xor ,a ,b))
			      ((bitwise-and) `(bitwise-and ,a ,b)))) ))))


(define-method (show-copies node::assigning-string-cat)
   (with-access::assigning-string-cat/gen node (lval rval lhs-is-output-port?)
      (if lhs-is-output-port?
	  (begin
	     ;this is just to make sure that the lval gets bound, in case
	     ;it's only used here
	     (show-copies lval)
	     `(display (mkstr ,@(strip-mkstr (get-value rval)))
		       ,(string-port-name (var-name lval))))
	  (update-value lval `(mkstr ,@(strip-mkstr (get-value lval))
				     ,@(strip-mkstr (get-value rval)))))))

(define-method (show-copies node::foreach-loop)
   (with-access::foreach-loop/gen node (location array key value body string-ports needs-break? needs-continue?)
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue))
	    (arrayname (gensym 'array))
	    (started? (gensym 'started?)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(let ((,arrayname (copy-php-data ,(get-value array)))
			  (,started? #f))
		       ,(explain-copy (cdr location) (car location) (ast-node->briefer-string array) " will be copied (foreach loop).")
		       (if (not (php-hash? ,arrayname))
			   (php-warning "not an array in foreach")
			   (begin
			      (php-hash-reset ,arrayname)
			      (let loop ()
				 (if ,started?
				     (php-hash-advance ,arrayname)
				     (set! ,started? #t))
				 (when (php-hash-has-current? ,arrayname)
				    ,(update-value value `(copy-php-data (php-hash-current-value ,arrayname)))
				    ,(unless (null? key)
					(update-value key `(php-hash-current-key ,arrayname)))
				    ,(bind-exit-if needs-continue? continuename
					(show-copies body))
				    (loop)))))))))))))



(define (string-port-name name)
   (symbol-append name '-port))

(define-method (show-copies node::while-loop)
   (with-access::while-loop/gen node (body condition string-ports needs-break? needs-continue?)
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(let loop ()
		       (when ,@(if (null? condition)
				   '(#t)
				   `(,(get-boolean condition)))
			     ,(bind-exit-if needs-continue? continuename
				 (show-copies body))
			     (loop))))))))))



(define-method (show-copies node::for-loop)
   (with-access::for-loop/gen node (init condition step body string-ports needs-continue? needs-break?)
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue))
	    (started? (gensym 'started?)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(begin
		       ,@(if (null? init)
			     '()
			     (list (show-copies init)))
		       (let ((,started? #f))
			  (let loop ()
			     
			     ;this is to make sure that the step is executed even if the user does a continue
			     ;and so that we only save the loop once
			     (if ,started?
				 ,@(if (null? step)
				       '()
				       (list (show-copies step)))
				 (begin
				    ;			    (set! *current-loop-continue* loop)
				    (set! ,started? #t)))
			     (when ,(if (null? condition)
					#t
					`(begin ,@(map get-boolean condition)))    ;(convert-to-boolean ,(show-copies condition))))
				(begin
				   ,@(if (null? body)
					 '()
					 (list
					  (bind-exit-if needs-continue? continuename
					     (show-copies body))))
				   (loop)))))))))))))

(define (bind-string-ports string-ports form)
   (if (null? string-ports)
       form
       ;bind the string ports
       `(let ,(map (lambda (name)
		      `(,(string-port-name name) (open-output-string)))
		   string-ports)
	   ;generate code to copy the previous value of the string that's being replaced
	   ;into its port
	   ,@(map (lambda (name)
		     `(display (mkstr ,name) ,(string-port-name name)))
		  string-ports)
	   (unwind-protect
	      ,form
	      ;generate code to copy strings out of the string-ports after the form
	      ,@(map (lambda (name)
			;; since atm only a var can be string-port-replaced, we can avoid
			;; the generalized update-value.  also, string-port-replacement
			;; only happens in code that gets type analyzed (atm), so we can use
			;; the symbol table to check for containerness.
			(if (types-eqv? (hashtable-get (current-symtab) name) 'container)
			    `(container-value-set! ,name (close-output-port ,(string-port-name name)))
			    `(set! ,name (close-output-port ,(string-port-name name)))))
		     string-ports)))))


(define-method (show-copies node::break-stmt)
   (with-access::break-stmt node (level)
      ;;unfortunately, in the general case, the continue and break stacks
      ;;must be reified.  see bug 2385
      (let ((the-level (if (null? level) 0 (show-copies level)))
	    (level (gensym 'level))
	    (break-stack (gensym 'break-stack)))
	 `(let ((,level (max 0 (- (mkfixnum ,the-level) 1)))
		(,break-stack (list ,@*break-stack*)))
	     (if (>= ,level (length ,break-stack))
		 (php-error (format "Cannot break ~A level~A"
				    (+ ,level 1) (if (> ,level 0) "s" "")))
		 ((list-ref ,break-stack ,level) #t))))))

; (define-method (show-copies node::continue-stmt)
;    (with-access::continue-stmt node (level)
;       (let ((level (if (null? level) 0 (max 0 (- (mkfixnum level) 1)))))
; 	 (if (>= level (length *continue-stack*))
; 	     (delayed-error/loc node (format "Cannot continue ~A level~A"
; 					     (+ level 1) (if (> level 0) "s" "")))
; 	     `((list-ref ',*continue-stack* level) #t)))))

(define-method (show-copies node::continue-stmt)
   (with-access::continue-stmt node (level)
      (let ((the-level (if (null? level) 0 (show-copies level)))
	    (level (gensym 'level))
	    (continue-stack (gensym 'continue-stack)))
	 `(let ((,level (max 0 (- (mkfixnum ,the-level) 1)))
		(,continue-stack (list ,@*continue-stack*)))
	     (if (>= ,level (length ,continue-stack))
		 (php-error (format "Cannot continue ~A level~A"
				    (+ ,level 1) (if (> ,level 0) "s" "")))
		 ((list-ref ,continue-stack ,level) #t))))))

(define-method (show-copies node::return-stmt/gen)
   (with-access::return-stmt/gen node (value cont?)
      (if cont?
	  `(return ,(get-location value))
	  `(return ,(get-copy value)))))

(define-method (show-copies node::exit-stmt)
   (with-access::exit-stmt node (rval)
      `(php-funcall 'php-exit ,@(if (null? rval)
				    '()
				    (list (get-value rval))))))


(define-method (show-copies node::if-stmt)
   (with-access::if-stmt node (condition then else)
      `(if ,(get-boolean condition)
	   ,(show-copies then)
	   ,(show-copies else))))

(define-method (show-copies node::lyteral)
   (lyteral-value node))

(define-method (show-copies node::literal-integer)
   (convert-to-number (lyteral-value node)))

(define-method (show-copies node::literal-float)
   (convert-to-number (lyteral-value node)))

(define-method (show-copies node::literal-string)
   (mkstr (lyteral-value node)))

(define-method (show-copies node::literal-null)
   ''())

(define-method (show-copies node::typecast)
   (with-access::typecast node (typecast rval)
      ;      (print "rval is: " rval ", get-value is " (get-value rval))
      (ecase typecast
	 ((boolean) (get-boolean rval))
	 ((object) `(convert-to-object ,(get-value rval)))	 
	 ((integer) `(convert-to-integer ,(get-value rval)))
	 ((float) `(convert-to-float ,(get-value rval)))
	 ((string) `(convert-to-string ,(get-value rval)))
	 ((hash) `(convert-to-hash ,(get-value rval))))))

(define-method (show-copies node::arithmetic-op)
   (with-access::arithmetic-op node (op a b)
      (let ((a-val (get-value a))
	    (b-val (get-value b)))
	 
	 (cond
	    ((and (compile-time-constant? a-val)
		  (compile-time-constant? b-val))
	     (ecase op
		((php--) (php-- a-val b-val))
		((php-+) (php-+ a-val b-val))
		((php-/) (php-/ a-val b-val))
		((php-*) (php-* a-val b-val))
		((php-%) (php-% a-val b-val))))
	    ((and (is-numeric? a)
		  (is-numeric? b))
	     (ecase op
		((php--) `(php--/num ,a-val ,b-val))
		((php-+) `(php-+/num ,a-val ,b-val))
		((php-/) `(php-//num ,a-val ,b-val))
		((php-*) `(php-*-/num ,a-val ,b-val))
		((php-%) `(php-% ,a-val ,b-val))) ) ;xxx zoot!
	    (else
	     (ecase op
		((php--) `(php-- ,a-val ,b-val))
		((php-+) `(php-+ ,a-val ,b-val))
		((php-/) `(php-/ ,a-val ,b-val))
		((php-*) `(php-* ,a-val ,b-val))
		((php-%) `(php-% ,a-val ,b-val))) )))))


(define-method (show-copies node::echo-stmt)
   (with-access::echo-stmt node (stuff)
      (if (list? stuff)
	  (if (> (length stuff) 1)
	      `(begin 
		  ,@(map (lambda (c)
			    `(echo ,(get-value c)))
			 stuff))
	      `(echo ,(get-value (car stuff))))
	  `(echo ,(get-value stuff)))))


(define-method (show-copies node::static-decl)
;   (print "generating-code node: " node  ", current-block " *current-block*)
   (with-access::static-decl node (var)
      (if (or (not (current-static-vars))
		  (hashtable-get (current-static-vars) var))
	  ''static-decl
	  (error 'show-copies-static-decl
		 "somehow this static-decl didn't get declared" node) )))

(define-method (show-copies node::global-decl)
   (with-access::global-decl node (var)
      (if (ast-node? var)
	  (let ((val (get-value var)))
	     ;; In this case, a var-var decl, you can only access the var
	     ;; with $$, not directly, because we don't know its name at
	     ;; compile time.
	     `(env-extend ,*current-var-var-env*
			  (mkstr ,val)
			  (env-lookup *global-env* (mkstr ,val))))
	  (begin
	     (add-binding-to-current-block var '(make-container '()))
	     `(begin
		 (set! ,var (env-lookup *global-env* ,(undollar var)))
		 (when ,*current-var-var-env*
		    (env-extend ,*current-var-var-env* ,(undollar var) ,var)))))))

(define-method (show-copies node::var)
   (with-access::var/gen node (name cont?)
      (if cont?
	  (add-binding-to-current-block name '(make-container '()))
	  (add-binding-to-current-block name ''()))
      (if (global-scope?)
;	  `(env-lookup *global-env* ,(undollar name))
	  ;; xxx should put an assert here
	  `(env-internal-index-value ,name)
	  name)))


(define-method (show-copies node::var-var)
   (with-access::var-var node (lval)
      (flag-needs-var-var-env!)
     `(env-lookup ,*current-var-var-env* (mkstr ,(get-value lval)))))

(define-method (show-copies node::assignment)
   (with-access::assignment/gen node (lval rval lhs-is-output-port?)
      (if lhs-is-output-port?
	  (begin
	     ;this is just to add the lval to the symtab so it gets bound
	     ;in case it's not used anyplace other than here
	     (show-copies lval)
	     ;assume the rval is of the form (mkstr lval ...) and strip lval off it
	     `(display ,(cons 'mkstr (cddr (show-copies rval)))
		       ,(string-port-name (var-name lval))))
	  (update-value lval (get-copy rval)))))

(define-method (show-copies node::disable-errors)
   (with-access::disable-errors node (body)
      `(begin
	  (dynamically-bind (*errors-disabled* #t)
	     ,(show-copies body) ))))


(define-method (show-copies node::list-assignment)
   (with-access::list-assignment node (lvals rval)
      (let ((rval-name (gensym 'rval)))
	 `(let ((,rval-name ,(get-value rval)))
	     (if (convert-to-boolean ,rval-name)
		 (begin
		    ,@(remq '()
			    (map (let ((i (length lvals)))
				    (lambda (var)
				       (set! i (- i 1))
				       (if (null? var)
					   '()
					   ;XXX copy?
					   (update-value var `(php-hash-lookup ,rval-name ,i)))))
				 (reverse lvals)))
		    ,rval-name)
		 #f)))))


		
(define-method (show-copies node::reference-assignment)
   (with-access::reference-assignment node (lval rval)
      (update-location lval (get-location rval))))


(define-method (show-copies node::unset-stmt)
   (with-access::unset-stmt node (lvals)
      `(begin ,@(map unset lvals))))


(define-method (show-copies node::switch-stmt)
   (with-access::switch-stmt/gen node (rval cases needs-continue? needs-break?)
      (if (null? cases)
	  ;;warn, evaluate just for side-effect
	  (begin
	     (warning/loc node "empty switch statement.")
	     (get-value rval))
	  (let ((breakname (gensym 'break))
		(switchflag (gensym 'switchflag))
		(switchvar (gensym 'switchvar)))
	     (dynamically-bind (*break-stack* (cons breakname *break-stack*))
		(dynamically-bind (*continue-stack* (cons breakname *continue-stack*))
		   (bind-exit-if (or needs-continue? needs-break?) breakname
		      `(let ((,switchflag #f)
			     (,switchvar ,(get-value rval)))
			  ,@(map
			     (lambda (c)
				(if (default-switch-case? c)
				    (with-access::default-switch-case c (body)
				       `(begin
					   (set! ,switchflag #t)
					   ,(show-copies body)))
				    ;				`(unless ,switchflag ,(show-copies body)))
				    (with-access::switch-case c (val body)
				       `(when (or ,switchflag
						  (equalp ,switchvar ,(get-value val)))
					   (set! ,switchflag #t)
					   ,(show-copies body)))))
			     cases)))))))))
	 
(define-method (show-copies node::do-loop)
   (with-access::do-loop/gen node (condition body string-ports needs-continue? needs-break? )
      (let ((breakname (gensym 'break))
	    (continuename (gensym 'continue)))
	 (dynamically-bind (*break-stack* (cons breakname *break-stack*))
	    (dynamically-bind (*continue-stack* (cons continuename *continue-stack*))
	       (bind-string-ports
		string-ports
		(bind-exit-if needs-break? breakname
		   `(let loop ()
		       ,(bind-exit-if needs-continue? continuename
			   (show-copies body))
		       (when ,(if (null? condition)
				  #t
				  (get-boolean condition))
			  (loop))))))))))

   


(define-method (show-copies node::class-decl)
   (error 'show-copies-class-decl "somehow this class didn't get declared" node))

(define-method (show-copies node::class-decl/gen)
   (with-access::class-decl/gen node (name canonical-name parent properties methods rendered?)
      (if rendered?
	  `(begin 'class-already-rendered ',name)
	  (begin
	     (let ((code '()))
		(pushf `(define-php-class ',name ',parent) code)
		(php-hash-for-each properties
		   (lambda (prop-name prop)
		      (pushf `(define-php-property ',name
				 ,prop-name
				 ,(if (null? (property-decl-value prop))
;				     '(make-container '())
;				     (get-location (property-decl-value prop))
				      ''()
				      (get-value (property-decl-value prop))
				     ))
			     code)))
		(dynamically-bind (*current-parent-class-name* parent)
		   (dynamically-bind (*current-class-name* name)
		      (php-hash-for-each methods
			 (lambda (method-name method)
			    (pushf `(define-php-method ',name
				       ',method-name
				       ,(show-copies method))
				   code)))))
		(cons 'begin (reverse code)))))))


(define-method (show-copies node::constructor-invoke)
   (with-access::constructor-invoke node (location class-name arglist)       
      `(begin
	  (set! *PHP-FILE* ,*file-were-compiling*)
	  (set! *PHP-LINE* ,(car location))
	  (begin0
	   (construct-php-object ,(if (ast-node? class-name)
				      (get-value class-name)
				      (mkstr class-name))
				 ,@(map get-location arglist))
	   (set! *PHP-FILE* ,*file-were-compiling*)
	   (set! *PHP-LINE* ,(car location))))))


(define-method (show-copies node::method-invoke)
   (with-access::method-invoke node (location method arglist)
      (with-access::property-fetch method (obj prop)
	 (let ((tramp (case (length arglist)
			 ((0) 'call-php-method-0)
			 ((1) 'call-php-method-1)
			 ((2) 'call-php-method-2)
			 ((3) 'call-php-method-3)
			 (else 'call-php-method)) ))
	    `(begin
		(set! *PHP-FILE* ,*file-were-compiling*)
		(set! *PHP-LINE* ,(car location))
		(begin0
		 (,tramp ,(dynamically-bind (*hash-lookup-writable* #t)
			     (get-value obj))
			 ,(if (ast-node? prop)
			      (get-value prop)
			      (undollar prop))
			 ,@(map get-location arglist))
		 (set! *PHP-FILE* ,*file-were-compiling*)
		 (set! *PHP-LINE* ,(car location)) ))))))


(define-method (show-copies node::static-method-invoke)
    (with-access::static-method-invoke node (location class-name method arglist)
       `(begin
	   (set! *PHP-FILE* ,*file-were-compiling*)
	   (set! *PHP-LINE* ,(car location))
	   (begin0
	    ,(if (and *current-class-name*
		      (compile-time-subclass? *current-class-name* class-name))
		 `(call-php-method this-unboxed ,(get-value method)
				   ,@(map get-location arglist))
		 `(call-static-php-method ',class-name ,(get-value method)
					  ,@(map get-location arglist)))
	      (set! *PHP-FILE* ,*file-were-compiling*)
	      (set! *PHP-LINE* ,(car location)) ))))
   
(define-method (show-copies node::parent-method-invoke)
   (with-access::parent-method-invoke node (location name arglist)
      (if *current-parent-class-name*
	  `(begin
	      (set! *PHP-FILE* ,*file-were-compiling*)
	      (set! *PHP-LINE* ,(car location))
	      (begin0
	       (call-php-parent-method ',*current-parent-class-name*
				       this-unboxed
				       ,(get-value name)
				       ,@(map get-location arglist))
	       (set! *PHP-FILE* ,*file-were-compiling*)
	       (set! *PHP-LINE* ,(car location)) ))
	  (delayed-error/loc node
			     (format "show-copies-parent-method-invoke: no parent class to be found ~a"
				     node)))))

(define-method (show-copies node::property-fetch)
   (with-access::property-fetch node (obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc node "property name is not a string, but should be."))
	 (if *hash-lookup-writable*
	     (if property-is-constant?
		 `(php-object-property/string
		   ,the-object ,(mkstr the-property))
		 `(php-object-property ,the-object ,the-property))
	     (if property-is-constant?
		 `(php-object-property-h-j-f-r/string
		   ,the-object ,(mkstr the-property))
		 `(php-object-property-honestly-just-for-reading ,the-object ,the-property))))))
			      
			 
(define-method (show-copies node::function-decl/gen)
   (with-access::function-decl/gen node
	 (location needs-env? name decl-arglist canonical-name container-table
		   variable-arity? toplevel? symbol-table static-vars body)
      (let ((param-names (map formal-param-name decl-arglist)))
	 ;generate the code for the body, so we know if we need an env
	 (dynamically-bind (*current-block* node)
	    (dynamically-bind (*current-var-var-env* (if needs-env? 'env #f))
	       ;we generate the code for the body first, because in the process the
	       ;symbol-table is filled, so we know which variables to bind
	       (let* ((body-code (show-copies body))
		      (signature-code
		       `(begin
			   ,@(if (needs-alias? canonical-name)
				 `((store-alias ',canonical-name ',(autoalias canonical-name)))
				 '())
			   ,(runtime-sig location (autoalias canonical-name) toplevel? variable-arity? decl-arglist))))
		  (set! body-code
			(profile-wrap
			 name
			 (trace-wrap
			  name param-names location
			  `(bind-exit (return)
			      (let ,(bindings symbol-table (append (hashtable-key-list static-vars) param-names))
				 ,@(copy-and-type-non-reference-args decl-arglist)
				 ,@(box-non-reference-container-args decl-arglist)
				 ,@(if variable-arity?
				       `((push-func-args (cons* ,@param-names rest-args)))
				       '())
				 (let ((env ,(if needs-env? '(env-new) #f))
				       (old-env *current-variable-environment*))
				    ,@(if needs-env?
					  `(,@(add-arguments-to-env decl-arglist)
					      ,@(add-bindings-to-env symbol-table)
					      ,@(add-bindings-to-env static-vars)
					      (set! *current-variable-environment* env))
					  '())
				    #t ;so it's never empty
				    ,body-code
				    ,@(if needs-env? `((set! *current-variable-environment* old-env)) '())
				    ,@(if variable-arity? `((pop-func-args)) '())
				    NULL)) ))))
		  (set! body-code
			`(lambda ,(let ((args param-names))
				(if variable-arity?
				    (if (null? args)
					'rest-args
					`(,@args . rest-args))
				    args))
			    ,@body-code))
		  (let ((static-bindings (bindings-generate static-vars container-table)))
		     (unless (null? static-bindings)
			(set! body-code `(let ,static-bindings ,body-code))))
		  (if toplevel? 
		      (begin
			 (pushf signature-code *runtime-function-sigs*)
			 (pushf `(define ,(autoalias canonical-name) ,body-code) *functions*)
			 (pushf (autoalias canonical-name) *exports*)
			 (make-nop '("in generate.scm" . "should be stripped")))
		      `(let ((,(autoalias canonical-name) ,body-code)) ,@(cdr signature-code)))))))))

(define-method (show-copies node::method-decl)
   (with-access::method-decl/gen node
	 (location name needs-env? decl-arglist canonical-name container-table
		   variable-arity? symbol-table static-vars body)
      ;generate the code for the body, so we know if we need an env
      (dynamically-bind (*current-block* node)
	 (dynamically-bind (*current-var-var-env* (if needs-env? 'env #f))
	    (let* ((body-code (show-copies body))
		   (method-fun-name (string->symbol (mkstr *current-class-name* "=>" name)))
		   (required-params (filter required-formal-param? decl-arglist))
		   (optional-params (filter optional-formal-param? decl-arglist)))
	       
	       
	       (hashtable-remove! symbol-table '$this)
	       (set! body-code
		     `(define ,method-fun-name
			 (let ,(bindings-generate static-vars container-table)
			    (lambda (this-unboxed ,@(map required-formal-param-name required-params)
					     . ,(if (or variable-arity? (pair? optional-params)) 'optional-args '()))
			       ;unbox the non-reference args
			       ,@(map (lambda (p)
					 `(set! ,(formal-param-name p)
						(container-value ,(formal-param-name p))))
				      (filter (lambda (a)
						 (not (formal-param-ref? a)))
					      required-params))
			       ;bind the optional params to their default values
			       (let ,(map (lambda (p)
					     `(,(optional-formal-param-name p)
					       ,(let ((default (optional-formal-param-default-value p)))
						   (if (ast-node? default)
						       (get-value default)
						       default))))
					  optional-params)
				  ;override the default with the actual passed value, if it was passed
				  ,@(map (lambda (p)
					    `(when (pair? optional-args)
						(set! ,(optional-formal-param-name p)
						      ,(if (optional-formal-param-ref? p)
							   '(car optional-args)
							   '(container-value (car optional-args))))
						(set! optional-args (cdr optional-args))))
					 optional-params)
				  ,@(profile-wrap
				     (string->symbol (mkstr *current-class-name* "::" name))
				     (trace-wrap
				      (mkstr *current-class-name* "::" name)
				      (map formal-param-name decl-arglist) location
				      `(bind-exit (return)
					  (let ((env ,(if needs-env? '(env-new) #f))
						(old-env *current-variable-environment*))
					     (let ,(bindings symbol-table (append (hashtable-key-list static-vars)
										  (map formal-param-name decl-arglist)))
						(let (($this ,(if (hashtable-get container-table '$this)
								  `(make-container this-unboxed)
								  'this-unboxed)))
						   ,@(copy-and-type-non-reference-args decl-arglist)
						   ,@(box-non-reference-container-args decl-arglist)
						   ,@(if variable-arity?
							 `((push-func-args
							    (cons* ,@(map required-formal-param-name required-params)
								   optional-args)))
							 '())
						   ,@(if needs-env?
							 `(,@(add-arguments-to-env decl-arglist)
							     ,@(add-bindings-to-env symbol-table)
							     ,@(add-bindings-to-env static-vars)
							     (set! *current-variable-environment* env))
							 '())
						   #t ;so it's never empty
						   ,body-code
						   ,@(if needs-env? `((set! *current-variable-environment* old-env)) '())
						   ,@(if variable-arity? `((pop-func-args)) '())
						   NULL)))))))))))

	       (pushf body-code *functions*)
	       method-fun-name)))))



(define-method (show-copies node::function-decl)
   (error 'show-copies-function-decl "function decl didn't get declared" node))


(define-method (show-copies node::constant-decl)
   (with-access::constant-decl node (name value insensitive?)
      (if (null? insensitive?)
	  `(store-constant ',(mkstr name) ,(get-value value) #f)
	  `(store-constant ',(mkstr name) ,(get-value value)
			   (convert-to-boolean ,(get-value insensitive?))))))

(define-method (show-copies node::php-constant)
   (with-access::php-constant node (name)
      ;;XXX Really, I don't want to be modifying this literal constant.
      ;;I'd rather have toplevel code like for the elongs.
      `(lookup-constant/smash '(,(mkstr name)))))

(define (strip-mkstr aval)
   ;this is so we can avoid nested mkstrs
   (if (and (pair? aval)
	    (eqv? 'mkstr (car aval)))
       (cdr aval)
       (list aval)))

(define-method (show-copies node::string-cat)
   (with-access::string-cat node (a b)
      (let ((a-val (get-value a))
	    (b-val (get-value b)))
	 (if (and (compile-time-constant? a-val)
		  (compile-time-constant? b-val))
	     (begin
		(mkstr a-val b-val))
	     `(mkstr ,@(strip-mkstr a-val)
		     ,@(strip-mkstr b-val))))))

(define-method (show-copies node::bitwise-op)
   (let ((a (get-value (bitwise-op-a node)))
	 (b (get-value (bitwise-op-b node)))
	 (op (bitwise-op-op node)))
      (ecase op
	 ((bitwise-or) `(bitwise-or ,a ,b))
	 ((bitwise-xor) `(bitwise-xor ,a ,b))
	 ((bitwise-and) `(bitwise-and ,a ,b))
	 ((bitwise-shift-left) `(bitwise-shift-left ,a ,b))
	 ((bitwise-shift-right) `(bitwise-shift-right ,a ,b))
	 (else (error 'show-copies-bitwise-op "don't know of operation" op)))))

(define-method (show-copies node::bitwise-not-op)
   `(bitwise-not ,(get-value (bitwise-not-op-a node))))

(define-method (show-copies node::comparator)
   (with-access::comparator node (op p q)
      (if (and (is-numeric? p) (is-numeric? q))
	  (let ((p (get-value p))
		(q (get-value q)))
	     (ecase op
		((identicalp equalp) `(equalp/num ,p ,q))
		((not-identical-p not-equal-p) `(not (equalp/num ,p ,q)))
		((less-than-p) `(less-than-p/num ,p ,q))
		((less-than-or-equal-p) `(less-than-or-equal-p/num ,p ,q))
		((greater-than-p) `(greater-than-p/num ,p ,q))
		((greater-than-or-equal-p) `(greater-than-or-equal-p/num ,p ,q))))
	  
	  (let ((p (get-value p))
		(q (get-value q)))
	     (ecase op
		((equalp) `(equalp ,p ,q))
		((not-equal-p) `(not (equalp ,p ,q)))
		((identicalp) `(identicalp ,p ,q))
		((not-identical-p) `(not-identical-p ,p ,q))
		((less-than-p) `(less-than-p ,p ,q))
		((less-than-or-equal-p) `(less-than-or-equal-p ,p ,q))
		((greater-than-p) `(greater-than-p ,p ,q))
		((greater-than-or-equal-p) `(greater-than-or-equal-p ,p ,q)))))))

(define-method (show-copies node::boolean-not)
   (with-access::boolean-not node (p)
      `(not ,(get-boolean p))))
;      (not (convert-to-boolean (show-copies p)))))


(define-method (show-copies node::boolean-or)
   (with-access::boolean-or node (p q)
      `(or ,(get-boolean p)
	   ,(get-boolean q))))

(define-method (show-copies node::boolean-and)
   (with-access::boolean-and node (p q)
      `(and ,(get-boolean p)
	    ,(get-boolean q))))


;;;;typed stuff
(define (is-numeric? thingy)
   (or (and (var/gen? thingy)
	    (equal? '(number) (var/gen-type thingy)))
       (eqv? 'number (node-return-type thingy))))

(define (is-hash? thingy)
   (or (and (var/gen? thingy)
	    (equal? '(hash) (var/gen-type thingy)))
       ;don't actually know any cases where this would matter, but...
       (eqv? 'hash (node-return-type thingy))))

(define (is-string? thingy)
   (or (and (var/gen? thingy)
	    (equal? '(string) (var/gen-type thingy)))
       (eqv? 'string (node-return-type thingy))))

(define-generic (get-copy rval)
     (get-value rval) )

(define-method (get-copy rval::ast-node)
   (with-access::ast-node rval (location) 
      (let ((ret-type (node-return-type rval)))
	 (case ret-type
	    ;strings can't be mutated by any operators we've given them
	    ((boolean number string) (get-value rval))
	    (else
	     (begin
		(explain-copy (cdr location) (car location) (ast-node->briefer-string rval) " will be copied.")
		`(copy-php-data ,(get-value rval))))))))

(define-method (get-copy rval::literal-array)
   (get-value rval))

(define-method (get-copy rval::literal-null)
   (get-value rval))

(define-method (get-copy rval::function-invoke)
   (get-value rval))

(define-method (get-copy rval::method-invoke)
   (get-value rval))

(define-method (get-copy rval::constructor-invoke)
   (get-value rval))

(define (get-boolean node)
   (if (or ;(var/boolean? node)
	   (eqv? 'boolean (node-return-type node)))
       (get-value node)
       `(convert-to-boolean ,(get-value node))))



;;;;get-value
(define-generic (get-value rval)
;   (fprint (current-error-port) "get value caught a " rval)
   `(maybe-unbox ',rval))

(define-method (get-value rval::ast-node)
;   (fprint (current-error-port) "other get value caught a " rval)
   (let ((ret-type (node-return-type rval)))
      (case ret-type
	 ((boolean number string object hash) (show-copies rval))
	 (else `(maybe-unbox ,(show-copies rval))))))


(define-method (get-value rval::hash-lookup)
   (show-copies rval))

(define-method (get-value rval::lyteral)
   (show-copies rval))

(define-method (get-value rval::var)
   ;   (if (eqv? *current-var-var-env* '*current-variable-environment*);<-- this is even hackier! '*global-env*)    
   ;this is a hack so that we can share the global environment between
   ;the compiler and the interpreter.  I hope to replace it with just a
   ;vector-ref.
   ;       `(container-value (env-lookup *global-env* ,(undollar (var-name rval))));',(show-copies rval)))
   (if (var/gen-cont? rval)
       `(container-value ,(show-copies rval))
       (show-copies rval)))

(define-method (get-value rval::function-invoke)
   `(maybe-unbox ,(show-copies rval)))

(define-method (get-value rval::method-invoke)
   `(maybe-unbox ,(show-copies rval)))

;;;;get-location
(define-generic (get-location rval)
   `(maybe-box ',rval))

(define-method (get-location rval::ast-node)
   ;note that this won't always return a container!
   ;this is used despite that, to allow us to share the global environment with interpreted code.
   (show-copies rval))

(define-method (get-location rval::hash-lookup)
   (with-access::hash-lookup rval (hash key)
      (let ((the-key (if (eqv? key :next)
			 :next
			 (get-value key))))
	 (if (is-hash? hash)
	     `(php-hash-lookup-ref ,(get-value hash) #f ,the-key)
	     `(begin
		 ,(update-value hash `(%coerce-for-insert ,(get-value hash)))
		 (%general-lookup-ref ,(get-value hash) ,the-key))))))

(define-method (get-location rval::property-fetch)
   (with-access::property-fetch rval (obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc rval "property name is not a string, but should be.")) 
	 (if property-is-constant?
	     `(php-object-property-ref/string
	       ,the-object ,(mkstr the-property))
	     `(php-object-property-ref ,the-object ,the-property)))))
	     
;XXX disable this for function-invoke for now
;(define-method (get-location rval::var)
;   (error 'get-location "tried to access the location of a normal var" rval))
   

(define-method (get-location rval::var)
       (show-copies rval));)

(define-method (get-location rval::function-invoke)
   `(maybe-box ,(show-copies rval)))

(define-method (get-location rval::method-invoke)
   `(maybe-box ,(show-copies rval)))

(define-method (get-location rval::constructor-invoke)
   `(make-container ,(show-copies rval)))

;;;;update-value
(define-generic (update-value lval rval-code)
   (let ((rval-name (gensym 'rval)))
      `(let ((,rval-name ,rval-code))
	  (container-value-set! ,(show-copies lval) ,rval-name)
	  ,rval-name)))

(define-method (update-value lval::var/gen rval-code)
   (if (var/gen-cont? lval)
        (let (;(lval-code (var-name lval))
	      (rval-name (gensym 'rval)))
	   `(let ((,rval-name ,rval-code))
	       (container-value-set! ,(show-copies lval) ,rval-name)
	       ,rval-name))
       (let ((lval-code (var-name lval))
	     (rval-name (gensym 'rval)))
	  (add-binding-to-current-block lval-code ''())
	  `(let ((,rval-name ,rval-code))
	      ,(if (global-scope?)
		   `(container-value-set! (env-lookup *global-env* ,(undollar lval-code)) ,rval-name)
		   `(set! ,lval-code ,rval-name))
	      ;it's okay that this isn't in a container, because it's not an ast-node,
	      ;so get-value & get-location treat it differently
	      ,rval-name))))

(define-method (update-value lval::hash-lookup rval-code)
   ;;this and update-location of hash-lookup are similar messes
   ;;really, they do about the same thing
   (let ((rval-name (gensym 'rval)))
      ;;this is to make sure that any property-lookups or hash-lookups
      ;;that we get-value of will be "separated" -- have any pending lazy
      ;;copies forced
      (dynamically-bind (*hash-lookup-writable* #t)
	 (with-access::hash-lookup lval (hash key)
	    ;;when dealing with a nested (multi-dimensional) hash-lookup,
	    ;;pass the list of keys to %general-insert-n!, instead of
	    ;;trying to generate some fancy nested insert code, which ends
	    ;;up multiply-evaluating key forms
	    (if (hash-lookup? hash)
		(let loop ((keys (list (if (eqv? key :next) :next (get-value key))))
			   (next hash))
		   (if (hash-lookup? next)
		       (with-access::hash-lookup next (hash key)
			  (loop (cons (if (eqv? key :next) :next (get-value key))
				      keys)
				hash))
		       `(let ((,rval-name ,rval-code))
			   ;;this is the base case.  make sure to return the rval,
			   ;;for cases like $a = $a[2] = $b[4]
			   ,(update-value next
					  `(%general-insert-n! (%coerce-for-insert ,(get-value next))
							       (list ,@keys)
							       ,rval-name))
			   ,rval-name)))
		(if (is-hash? hash)
		    ;simpler version for typed var	
		    `(php-hash-insert! ,(get-value hash)
				       ,(if (eqv? key :next) :next (get-value key))
				       ,rval-code)
		    ;hairy version for untyped var
		    `(let ((,rval-name ,rval-code))
			,(update-value hash `(%general-insert!
					      (%coerce-for-insert ,(get-value hash))
					      ,(if (eqv? key :next) :next (get-value key))
					      ,rval-name))
			,rval-name)))))))

(define-method (update-value lval::property-fetch rval-code)
   (with-access::property-fetch lval (obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc lval "property name is not a string, but should be."))
	 (if property-is-constant?
	     `(php-object-property-set!/string
	       ,the-object
	       ,(mkstr the-property)
	       (maybe-unbox ,rval-code))
	     `(php-object-property-set! ,the-object ,the-property (maybe-unbox ,rval-code))))))

;;;;unset
(define-generic (unset lval)
   (update-value lval ''()))
;   (error 'unset "don't know how to unset lval" lval))


(define-method (unset lval::hash-lookup)
   (with-access::hash-lookup lval (hash key)
      (if (is-hash? hash)
	  `(php-hash-remove! ,(get-value hash)
			     ,(if (eqv? key :next)
				  ':next
				  (get-value key)))
	  (let ((hash-name (gensym 'hash)))
	     `(let ((,hash-name ,(get-value hash)))
		 (when (php-hash? ,hash-name)
		    (php-hash-remove! ,hash-name
				      ,(if (eqv? key :next)
					   ':next
					   (get-value key))) ) )))))

;;;;update-location
(define-generic (update-location lval rval-code)
   (error 'update-location-generic "unable to assign to location"
	  (cons lval rval-code)))


(define-method (update-location lval::var-var rval-code)
   (with-access::var-var lval (lval)
      (let ((name (gensym 'name))
	    (value (gensym 'val)))
	 `(let ((,name (mkstr ,(get-value lval)))
		(,value (maybe-box ,rval-code)))
	     (env-extend ,*current-var-var-env* ,name (maybe-box ,value))
	     ,@(refresh-lexicals)
	     ,value))))

(define (refresh-lexicals)
   (map (lambda (name)
	   `(set! ,name (env-lookup ,*current-var-var-env* ,(undollar name))))
	(cond
	   ((method-decl/gen? *current-block*)
	    (method-decl/gen-variable-names *current-block*))
	   ((function-decl/gen? *current-block*)
	    (function-decl/gen-variable-names *current-block*))
	   (else '()))))

(define-method (update-location lval::var/gen rval-code)
   (if (var/gen-cont? lval)
       (let ((name (var-name lval)))
	  (add-binding-to-current-block name '(make-container '()))
	  (if (global-scope?)
	      (let ((rval-name (gensym 'rval)))
		 `(let ((,rval-name ,rval-code))
		     (env-internal-index-value-set! ,name (maybe-box ,rval-name))
		     ,rval-name))
	      `(begin
		  (set! ,name ,rval-code)
		  (when ,*current-var-var-env*
		     (env-extend ,*current-var-var-env* ,(undollar name) ,name))
		  ,name)))
       (error 'update-location-var "tried to update the location of an unboxed variable" lval)))

(define-method (update-location lval::property-fetch rval-code)
   (with-access::property-fetch lval (obj prop)
      (let* ((the-object (get-value obj))
	     (the-property (if (ast-node? prop)
			       (get-value prop)
			       (mkstr prop)))
	     (property-is-constant? (compile-time-constant? the-property)))
	 (when (and property-is-constant? (not (string? the-property)))
	    (warning/loc lval "property name is not a string, but should be."))
	 (if property-is-constant?
	     `(php-object-property-set!/string
	       ,the-object ,(mkstr the-property) (maybe-box ,rval-code))
	     `(php-object-property-set! ,the-object ,the-property (maybe-box ,rval-code))))))


(define-method (update-location lval::hash-lookup rval-code)
   (let ((rval-name (gensym 'rval)))
      (dynamically-bind (*hash-lookup-writable* #t)
	 (with-access::hash-lookup lval (hash key)
	    (if (hash-lookup? hash)
		(let loop ((keys (list (if (eqv? key :next) :next (get-value key))))
			   (next hash))
		   (if (hash-lookup? next)
		       (with-access::hash-lookup next (hash key)
			  (loop (cons (if (eqv? key :next) :next (get-value key))
				      keys)
				hash))
		       `(let ((,rval-name ,rval-code))
			   ,(update-value next
					  `(%general-insert-n! (%coerce-for-insert ,(get-value next))
							       (list ,@keys)
							       ,rval-name))
			   ,rval-name)))
		(let ((the-key (if (eqv? key :next) :next (get-value key))))
		   (cond
		      ;kludge for globals, since reference assignment doesn't do what you want there
		      ((and (var? hash) (eqv? '$GLOBALS (var-name hash)))
		       (update-value lval `(maybe-unbox ,rval-code)))
		      ((is-hash? hash)
		       `(let ((,rval-name ,rval-code))
			   (php-hash-insert! ,(get-value hash)
					     ,the-key
					     ,rval-name)))
		      (else
		       `(let ((,rval-name ,rval-code))
			   ,(update-value hash `(%coerce-for-insert ,(get-value hash)))
			   (%general-insert! ,(get-value hash) ,the-key ,rval-name)
			   ,rval-name)))))))))



;;;;utilities
(define (current-symtab)
   (cond
      ((function-decl/gen? *current-block*)
       (function-decl/gen-symbol-table *current-block*))
      ((method-decl/gen? *current-block*)
       (method-decl/gen-symbol-table *current-block*))
      ((php-ast/gen? *current-block*)
       (php-ast/gen-global-symbol-table *current-block*))
      (else (error 'current-symtab "something is screwed" *current-block*))))

(define (current-static-vars)
   (cond
      ((function-decl/gen? *current-block*)
       (function-decl/gen-static-vars *current-block*))
      ((method-decl/gen? *current-block*)
       (method-decl/gen-static-vars *current-block*))
      ((php-ast/gen? *current-block*) #f)
      (else (error 'current-static-vars "something is screwed" *current-block*))))

(define (flag-needs-var-var-env!)
   (cond
      ((function-decl/gen? *current-block*)
       (function-decl/gen-needs-env?-set! *current-block* #t))
      ((method-decl/gen? *current-block*)
       (method-decl/gen-needs-env?-set! *current-block* #t))))


(define (global-bindings)
   (let ((code '()))
      (hashtable-for-each (current-symtab)
	 (lambda (key val)
	    (pushf `(,key (env-lookup-internal-index ,*current-var-var-env* ,(undollar key))) code)))
      code))

(define (bindings symbol-table exclude)
   ;;symbol-table is a hashtable of names and values
   ;;exclude is the ones that we shouldn't generate bindings for
   (let ((bindings '()))
      (hashtable-for-each symbol-table
	 (lambda (key type)
	    (unless (memv key exclude)
	       (pushf
		(if (superglobal? key)
		    ;this might not make the most sense, but works for superglobals which are hashtables.
		    `(,key (maybe-unbox (env-lookup *global-env* ,(undollar key))))
		    (cond
		       ((types-eqv? type 'container) `(,(symbol-append key '::pair) (make-container '())))
		       ((types-eqv? type 'number) `(,(symbol-append key '::onum) *zero*)) ;;onum?
		       ((types-eqv? type 'string) `(,(symbol-append key '::bstring) ""))
		       ((types-eqv? type 'hash) `(,(symbol-append key '::struct) (make-php-hash)))
		       (else `(,key '()))))
		bindings))))
      bindings))

(define (bindings-generate symbol-table container-table)
   ;like bindings, but call show-copies on the values
   (let ((bindings '()))
      (hashtable-for-each symbol-table
	 (lambda (key val)
	    (pushf (list key (if (superglobal? key)
				 ;this might not make the most sense, but works for superglobals which are hashtables.
				 `(maybe-unbox (env-lookup *global-env* ,(undollar key)))
				 (let ((val-code			     
					(cond ((null? val) ''())
					      ((ast-node? val) (show-copies val))
					      (else val))))
				    (if (hashtable-get container-table key)
					`(maybe-box ,val-code)
					`(maybe-unbox ,val-code)))))
		   
		   bindings)))
      bindings))


(define (superglobal? key::symbol)
   (let ((name (undollar key)));(symbol->string key)))
      ;      (set! name (substring name 1 (string-length name)))
      (hashtable-get *superglobals* name)))

(define (add-bindings-to-env symbol-table)
   (let ((code '()))
      (hashtable-for-each symbol-table
	 (lambda (key val)
	    (pushf `(env-extend ,*current-var-var-env* ,(undollar key) ,key) code)))
      code))

(define (add-arguments-to-env args)
   ;we assume that we'll never have more args than params, because PHP can't define
   ;var-arity functions, just optional params
    (let loop ((args args)
	       (code '()))
       (if (null? args)
	   code
	   (loop (cdr args)
		 (cons `(env-extend ,*current-var-var-env*
				    ,(undollar (formal-param-name (car args)))
				    ,(formal-param-name (car args)))
		       code)))))


(define (add-binding-to-current-block name value)
   ;; once upon a time, a list of all variables in a function was built
   ;; up using add-binding-to-current-block while generating code.  Now
   ;; the symbol table is used, and it should be populated already.  You
   ;; might expect it to be populated in the declare phase, but that would
   ;; be too easy.  It's populated by cfa, so that it serves as a sanity check.
   ;; Here, the old add-binding-to-current-block code is being used to verify
   ;; that no variables got missed.  
   (let ((symtab (current-symtab)))
      (unless (hashtable-get symtab name)
	 (if (ast-node? *current-block*)
	     (delayed-error/loc *current-block* (mkstr "variable "  name " not found in symtab"))
	     (delayed-error (mkstr "likely global, variable "  name " not found in symtab"))))))

   
(define (function-invoke-ref? function)
   #f)
(define (method-invoke-ref? function)
   #f)


(define (pass-argument from to)
   (if from
       ; to reference or not to reference
       (if (sig-param-ref? to)
	   (get-location from)
	   (get-value from)) ;maybe-copy
       (if (ast-node? (sig-param-default-value to))
	   (show-copies
	    (sig-param-default-value to))
	   (sig-param-default-value to))))

(define (box-non-reference-container-args arglist)
   (map (lambda (a)
	   (with-access::formal-param a (name)
	      `(set! ,name (make-container ,name))))
	(filter (lambda (a)
		   (or (and (required-formal-param? a) (required-formal-param/gen-cont? a));(required-formal-param/cont? a)
		       (and (optional-formal-param? a) (optional-formal-param/gen-cont? a))));		       (optional-formal-param/cont? a)))
		arglist)))

(define (copy-and-type-non-reference-args arglist)
   (remove null?
	   (map (lambda (a)
		   (with-access::formal-param a (location name ref?)
		      (cond
			 (ref? '())
			 ; 			 ((or (optional-formal-param/hash? a) (required-formal-param/hash? a))
			 ; 			  `(set! ,name (copy-php-data (convert-to-hash ,name) #f)))
			 ((or (and (required-formal-param/gen? a)
				   (not (required-formal-param/gen-needs-copy? a)))
			      (and (optional-formal-param/gen? a)
				   (not (optional-formal-param/gen-needs-copy? a))))
			  '())
			 (else
			  (begin
			     (explain-copy (cdr location) (car location) "parameter " name " will be copied.")
			     `(set! ,name (copy-php-data ,name)) )))))
		arglist)))



(define (runtime-sig location name toplevel? variable-arity? params)
   (let ((maximum-arity (if variable-arity? -1 (length params)))
	 (minimum-arity 0)
	 (store-routine (case (length params)
			   ((0) 'store-signature-0)
			   ((1) 'store-signature-1)
			   ((2) 'store-signature-2)
			   ((3) 'store-signature-3)
			   (else 'store-signature)))
	 
	 (brief-params '()))
      (map (lambda (a)
	      (if (required-formal-param? a)
		  (with-access::required-formal-param a (name ref?)
		     (set! minimum-arity (+fx minimum-arity 1))
		     (set! brief-params
			   (cons* (if ref? t-reference t-required)
				  `',name 0 brief-params)))
		  (with-access::optional-formal-param a (name default-value ref?)
		     (set! brief-params
			   (cons* (if ref? t-optional-reference t-optional)
				  `',name (get-value default-value) brief-params)))))
	   (reverse params))
      (if toplevel?
	  `(,store-routine ,name ,ft-user-compiled ',location ',name ,minimum-arity ,maximum-arity ,@brief-params)
	  `(let ((sig (store-signature ,name ,ft-user-compiled ',location ',name ,minimum-arity ,maximum-arity ,@brief-params)))
	      (sig-function-set! sig ,name)))))



(define (calculate-class-heritage klass)
   "calculate a class's lineage"
   (let loop ((heritage '())
	      (klass klass))
      (if (convert-to-boolean klass)
	  (loop (cons (mkstr (symbol-downcase (class-decl-name klass))) heritage)
		(if (null? (class-decl-parent klass))
		    #f
		    (php-hash-lookup *class-decl-table* (symbol-downcase (class-decl-parent klass)))))
	  (reverse (cons "stdClass" heritage)))))

(define (undollar str)
   (let ((str (mkstr str)))
      (if (char=? (string-ref str 0) #\$)
	  (substring str 1 (string-length str))
	  str)))


(define (compile-time-constant? x)
   (or (string? x)
       (php-number? x)
       (boolean? x)))

(define (trace-wrap name param-names location . code)
   (if *unsafe?*
       code
       (let ((retvalname (gensym 'ret)))
	  `((push-stack ',name ,@param-names)
	    (set! *PHP-LINE* ,(car location))
	    (set! *PHP-FILE* ,*file-were-compiling*)
	    (let ((,retvalname (begin ,@code)))
	       (pop-stack)
	       ,retvalname)))))

(define (profile-wrap name code)
   (if (not *source-level-profile*)
       code
       (let ((retvalname (gensym 'ret)))
	  `((profile-enter ',name)
	    (let ((,retvalname (begin ,@code)))
	       (profile-leave ',name)
	       ,retvalname)))))

(define (bind-exit-if condition exit-name code)
   (if condition
       `(bind-exit (,exit-name)
	   ,code)
       code))

(define (global-scope?)
   ;; are we currently in global scope?  I.e. should variables be treated
   ;; as globals.
   (eq? *current-var-var-env* '*current-variable-environment*))


;;;; this stuff isn't in generate.scm

(define (explain-copy file line . rest)
   (apply print "[COPY] " file ":" line " -- " rest))


;;; make a half-hearted attempt to print ast nodes more briefly
(define (ast-node->briefer-string node)
   (cond
      ((string? node) node)
      ((symbol? node) (mkstr node))
      ((lyteral? node) (mkstr (get-value node)))
      ((var? node) (mkstr (var-name node)))
      ((hash-lookup? node) (mkstr (ast-node->briefer-string (hash-lookup-hash node))
				  "["
				  (ast-node->briefer-string (hash-lookup-key node))
				  "]"))
      ((property-fetch? node) (mkstr (ast-node->briefer-string (property-fetch-obj node))
				     "->"
				     (ast-node->briefer-string (property-fetch-prop node))))
      (else (ast-node->brief-string node))))

