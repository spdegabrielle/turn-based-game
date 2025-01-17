#lang agile

(provide computer/score-explore-random)

(require racket/bool
         racket/hash
         (only-in racket/set set-intersect)
         "../turn-based-game.rkt"
         "../computer-player.rkt")

(define pair cons)

;; ----------------------------------------------------------------------------

;; An automated connect-four player that explores `n` moves ahead, and for each
;; board state after that randomly explores `p` different paths of `k` moves
;; ahead, scoring each board according to the percentage of those paths that
;; produce winning and non-losing results.

;; ----------------------------------------------------------------------------

;; Data Definitions

;; A State is one of:
;;  - #false
;;  - Result

;; A Result is a (result WinInfo Score [List-of ChoiceResult])
(struct result [win-info score nexts] #:transparent)

;; A WinInfo is one of:
;;  - #false        ; represents unknown
;;  - [Listof Side] ; represents a forcable end with these winners
;; An empty list represents a forcable tie.

;; win-info : TBG GameState -> WinInfo
(define (win-info tbg game)
  (define wins?
    (for/list ([s (in-list (sides tbg game))]
               #:when (winning-state? tbg game s))
      s))
  (cond [(not (empty? wins?)) wins?]
        [else #false]))

;; A ChoiceResult is a (choice-result MoveChoice State)
(struct choice-result [move state] #:transparent)

;; choice-result-win-info : ChoiceResult -> WinInfo
(define (choice-result-win-info c)
  (match (choice-result-state c)
    [#false #false]
    [(result wininfo _ _) wininfo]))

;; choice-result-winner? : ChoiceResult Side -> Boolean
(define (choice-result-winner? c side)
  (define wininfo (choice-result-win-info c))
  (and wininfo (member side wininfo) #t))

;; choice-result-score : ChoiceResult -> Score
(define (choice-result-score c)
  (match (choice-result-state c)
    [#false (hash)]
    [(result _ score _) score]))

;; INIT-STATE : State
(define INIT-STATE #false)

;; ----------------------------------------------------------------------------

;; A Score is a [Hashof Side Nat]

;; score-sum : [Listof Score] -> Score
(define (score-sum scores)
  (cond
    [(empty? scores) (hash)]
    [else
     (apply hash-union scores #:combine +)]))

;; choice-result-score/percentage : Side -> [ChoiceResult -> Real[0,1]]
(define ((choice-result-score/percentage s) c)
  (define score (choice-result-score c))
  (cond [(hash-has-key? score s)
         (/ (hash-ref score s)
            (for/sum ([(k v) (in-hash score)]) v))]
        [else 0]))

;; ----------------------------------------------------------------------------

;; The computer-player instance

(struct computer/score-explore-random [n p k]

  #:methods gen:computer-player
  [;; computer-player-start-state : Comp -> State
   (define (computer-player-start-state self)
     INIT-STATE)

   ;; computer-player-next-state : Comp TBG State GameState Side -> State
   (define (computer-player-next-state self tbg state game side)
     (match-define (computer/score-explore-random n p k) self)
     (next-state/depth tbg state game side (* 2 n) p (* 2 k)))

   ;; computer-player-state-moves :
   ;; Comp TBG State GameState Side -> [Listof MoveChoice]
   (define (computer-player-state-moves self tbg state game side)
     (cond [(false? state) (valid-move-choices tbg game side)]
           [else (map choice-result-move (result-nexts state))]))

   ;; computer-player-state-add-move : Comp TBG State Side MoveChoice -> State
   (define (computer-player-state-add-move self tbg state side move)
     (cond
       [(false? state) #false]
       [(result? state)
        (lookup-move-result (result-nexts state) side move)]))])

;; ----------------------------------------------------------------------------

;; next-state/depth : TBG State GameState Side Natural -> State
;; Goes d levels deep.
(define (next-state/depth tbg state game side dn p dk)
  (cond
    [(or (false? state) (zero? dn))
     (best-outcomes tbg game side dn p dk (valid-move-choices tbg game side))]
    [(result? state)
     ;; update-choice-result : ChoiceResult -> ChoiceResult
     (define (update-choice-result c)
       (define move (choice-result-move c))
       (choice-result
        move
        (next-state/depth tbg (choice-result-state c)
                          (play-move-choice tbg game side move)
                          (next-side tbg game side)
                          (sub1 dn)
                          p
                          dk)))
     (define old-next-states
       (map choice-result-state (result-nexts state)))
     (define choices
       (map update-choice-result (result-nexts state)))
     ;; optimization: if the updated choices result in the same winner
     ;;               possibilities, just use them all without filtering
     (cond
       [(and (andmap result? old-next-states)
             (equal? (map result-win-info old-next-states)
                     (map result-win-info (map choice-result-state choices))))
        (result (result-win-info state)
                (score-sum (map choice-result-score choices))
                choices)]
       [else
        (best-choices tbg game side choices)])]))

;; ----------------------------------------------------------------------------



;; ----------------------------------------------------------------------------

;; best-outcomes : TBG GameState Side Nat Nat Nat [List-of MoveChoice] -> State
(define (best-outcomes tbg game side dn p dk mvs)
  (define wininfo (win-info tbg game))
  (cond
    [wininfo (imm-win wininfo)]
    [(zero? dn)
     (score-explore-random tbg game side p dk mvs)]
    [(empty? mvs) IMM-TIE]
    [else
     ;; next-outcome : MoveChoice -> ChoiceResult
     (define (next-outcome c)
       (define game* (play-move-choice tbg game side c))
       (define side* (next-side tbg game* side))
       (choice-result
        c
        (best-outcomes tbg game* side* (sub1 dn) p dk
                       (valid-move-choices tbg game* side*))))
     (best-choices tbg game side (map next-outcome mvs))]))

;; score-explore-random :
;; TBG GameState Side Nat Nat [Listof MoveChoice] -> State
(define (score-explore-random tbg game side p dk mvs)
  (cond [(zero? dk)
         (result #false
                 (hash)
                 (map (λ (mv) (choice-result mv #false)) mvs))]
        [else
         ;; paths : [Listof PathDesc]
         ;; A PathDesc is a [Pair Score [Listof MoveDesc]]
         ;; A MoveDesc is a [Pair MoveChoice [Listof MoveChoice]]
         (define paths
           (for/list ([i (in-range p)])
             (let loop ([game game] [side side] [mvs mvs] [dk dk] [acc '()])
               ;; acc : [Listof MoveDesc]
               (cond [(or (zero? dk) (empty? mvs))
                      (pair (for/hash ([s (in-list (sides tbg game))]
                                       #:when (winning-state? tbg game s))
                              (values s 1))
                            (reverse acc))]
                     [else
                      (define mv (random-element mvs))
                      (define game* (play-move-choice tbg game side mv))
                      (define side* (next-side tbg game* side))
                      (loop game*
                            side*
                            (valid-move-choices tbg game* side*)
                            (sub1 dk)
                            (cons (pair mv mvs)
                                  acc))]))))
         (define scores (map car paths))
         (define move-descss (map cdr paths))
         (define total-score (score-sum scores))
         (define tree ; State
           (for/fold ([tree #false])
                     ([score (in-list scores)]
                      [move-descs (in-list move-descss)])
             (let loop ([tree tree] [move-descs move-descs])
               (cond [(empty? move-descs) tree]
                     [else
                      (define move (car (first move-descs)))
                      (define mvs (cdr (first move-descs)))
                      (match tree
                        [#false
                         (result
                          #false
                          score
                          (for/list ([mv (in-list mvs)])
                            (if (equal? move mv)
                                (choice-result
                                 mv
                                 (loop #false (rest move-descs)))
                                (choice-result
                                 mv
                                 #false))))]
                        [(result wininfo existing-score cs)
                         (result
                          wininfo
                          (score-sum (list existing-score score))
                          (for/list ([c (in-list cs)])
                            (match c
                              [(choice-result (== move) sub)
                               (choice-result
                                move
                                (loop sub (rest move-descs)))]
                              [_ c])))])]))))
         tree]))

;; best-choices : TBG GameState Side [List-of ChoiceResult] -> Result
(define (best-choices tbg game side choices)
  ;; winning-choice? : ChoiceResult -> Boolean
  (define (winning-choice? entry) (choice-result-winner? entry side))
  ;; non-losing-choice? : ChoiceResult -> Boolean
  ;; ASSUME not a winning choice
  (define (non-losing-choice? entry)
    (or (empty? (choice-result-win-info entry))
        (false? (choice-result-win-info entry))))
  ;; choice-result-score/side : ChoiceResult -> Real[0,1]
  (define choice-result-score/side (choice-result-score/percentage side))

  (define winning-choices
    (filter winning-choice? choices))
  (cond
    [(not (empty? winning-choices))
     ;; TODO: What to do if there are multiple winning choices
     ;; but they have different winner groups? (All including me)
     (result (list side)
             (score-sum (map choice-result-score choices))
             winning-choices)]
    [else
     (define non-losing-choices
       (filter non-losing-choice? choices))
     (cond
       [(not (empty? non-losing-choices))
        (define best
          (apply max (map choice-result-score/side non-losing-choices)))
        (result #false
                (score-sum (map choice-result-score choices))
                (filter (λ (c) (= best (choice-result-score/side c)))
                        non-losing-choices))]
       [else
        (define best
          (apply max (map choice-result-score/side choices)))
        ;; TODO: What to do if there are multiple losing choices
        ;; but they have different winner groups? (None including me)
        ;; If there is a set of sides that is included in all winner groups
        ;; (which feels like it should be true but I'm not sure)
        ;; then put that set in the win-info
        (define winners
          (apply set-intersect (map choice-result-win-info choices)))
        (result winners
                (score-sum (map choice-result-score choices))
                (filter (λ (c) (= best (choice-result-score/side c)))
                        choices))])]))

;; ----------------------------------------------------------------------------

;; lookup-move-result : [List-of ChoiceResult] Side MoveChoice -> State
(define (lookup-move-result choices side move)
  (cond
    [(empty? choices) #false]
    [(cons? choices)
     (if (equal? move (choice-result-move (first choices)))
         (choice-result-state (first choices))
         (lookup-move-result (rest choices) side move))]))

;; ----------------------------------------------------------------------------

;; States for immediate wins or ties

;; imm-win : WinInfo -> Result
(define (imm-win wininfo)
  (cond [wininfo
         (result wininfo (for/hash ([w (in-list wininfo)]) (values w 1)) '())]
        [else
         (result #false (hash) '())]))

;; IMM-TIE : Result
(define IMM-TIE (imm-win '()))

;; ------------------------------------------------------------------------

(define (random-element lst)
  (list-ref lst (random (length lst))))

;; ----------------------------------------------------------------------------

