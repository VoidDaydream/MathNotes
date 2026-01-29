#import "../../common.typ": noindent, project

#show: project

= What is a Proof?

== Propositions

*Definition.* A _proposition_ is a statement (communication) that is either true or false.

For a computer scientist, some of the most important things to prove are the correctness of programs and systems—whether a program or system does what it’s supposed to. Programs are notoriously buggy, and there’s a growing community of researchers and practitioners trying to find ways to prove program correctness.

== Predicates

A _predicate_ can be understood as a proposition whose truth depends on the value of one or more variables. Remember, nothing says that the proposition has to be true.

If $P$ is a predicate, then $P(n)$ is either true or false, depending on the value of $n$.

== The Axiomatic Method

Propositions like these that are simply accepted as true are called axioms. A proof is a sequence of logical deductions from axioms and previously proved statements that concludes with the proposition in question.

There are several common terms for a proposition that has been proved. The different terms hint at the role of the proposition within a larger body of work.

- Import true propositions are called _theorems_.
- A _lemma_ is a preliminary proposition useful for proving later propositions.
- A _corollary_ is a proposition that follows in just a few logical steps from a theorem.

== Our Axioms

== Logical Deductions

#let inference(rule_name, body) = {
  block(width: 100%, inset: (top: 0.5em, bottom: 0.5em))[
    *#rule_name*
    #v(0.5em)
    #body
  ]
}

Logical deductions, or inference rules, are used to prove new propositions using previously proved ones.

A fundamental inference rule is _modus ponens_. This rule says that a proof of P together with a proof that P IMPLIES Q is a proof of Q. _Modus ponens_ is written:

#inference([Rule.])[
  $ (P, P "IMPLIES" Q)/(Q) $
]

#h(1em)When the statements above the line, called the antecedents, are proved, then we can consider the statement below the line, called the conclusion or consequent,to also be proved.

A key requirement of an inference rule is that it must be sound: an assignment of truth values to the letters, P , Q, . . . , that makes all the antecedents true must also make the consequent true. So if we start off with true axioms and apply sound inference rules, everything we prove will also be true.

There are many other natural, sound inference rules, for example:

#inference([Rule.])[
  $ (P "IMPLES" Q, Q "IMPLIES" R)/(P "IMPLIES" R) $
]

#inference([Rule.])[
  $ ("NOT(P) IMPLES NOT(Q)")/(Q "IMPLES" P) $
]

#inference([Non-Rule.])[
  $ (P, P "IMPLIES" Q)/(Q) $
]
is not sound: if P is assigned T and Q is assigned F, then the antecedent is true and the consequent is not.

== Proving an Implication
Propositions of the form “If P, then Q” are called implications. This implication is often rephrased as “P IMPLIES Q.”

=== Method #1

In order to prove that P IMPLIES Q:
1. Write, “Assume P."
2. Show that Q logically follows.

=== Method #2 -  Prove the Contrapositive
An implication (“P IMPLIES Q”) is logically equivalent to its contrapositive
$"NOT(Q) IMPLES NOT (P)" .$
Proving one is as good as proving the other, and proving the contrapositive is sometimes easier than proving the original statement. If so, then you can proceed as follows:
1. Write, “We prove the contrapositive:” and then state the contrapositive.
2. Proceed as in Method #1.

== Proving an "If and Only If"
Many mathematical theorems assert that two statements are logically equivalent; that is, one holds if and only if the other does.

=== Method #1: Prove Each Statement Implies the Other

The statement “P IFF Q” is equivalent to the two statements “P IMPLIES Q” and “Q IMPLIES P .” So you can prove an “iff” by proving two implications:
1. Write, “We prove P implies Q and vice-versa.”
2. Write, “First, we show P implies Q.” Do this by one of the methods at above.
3. Write, “Now, we show Q implies P .” Again, do this by one of the methods at above.


=== Method #2: Construct a Chain of Iffs
In order to prove that P is true iff Q is true:
1. Write, “We construct a chain of if-and-only-if implications.”
2. Prove P is equivalent to a second statement which is equivalent to a third statement and so forth until you reach Q.

== Proof by Cases

Breaking a complicated proof into cases and proving each case separately is a common, useful proof strategy. 

== Proof by Contradiction

In a proof by contradiction, or indirect proof, you show that if a proposition were false, then some false fact would be true. Since a false fact by definition can’t be true, the proposition must be true.

Proof by contradiction is always a viable approach. However, as the name sug-gests, indirect proofs can be a little convoluted, so direct proofs are generally prefer-able when they are available.

Method: In order to prove a proposition P by contradiction:
1. Write, "We use proof by contradiction."
2. Write, "Suppose P is false."
3. Deduce something known to be false (a logical contradiction).
4. Write, "This is a contradiction. Therefore, P must be true."

== Good Proofs in Practice

state your game plan
keep a linear flow
A proof is an essay, not a calculation
Avoid excessive symbolism.
Revise and simplify.
Introduce notation thoughtfully.
Structure long proofs.
Be wary of the "obvious".
Finish.