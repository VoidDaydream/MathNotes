In the language of conditional probability, we wish to compute the probability $PP[A|B]$, which we read as "the conditional probability of A given B."

If they all simply inherited their probability from $Omega$, then the sum of these probabilities would be $sum_(omega in B)PP[omega]=PP[B]$, which in general is less then 1. So, to get the correct normalization, we need to scale the probability of each sample point by
$1/PP[B]$. That is, for each sample point
,the new probability becomes $ PP[omega|B] = PP[omega]/PP[B]. $

Now it is clear how to compute $PP[A|B]$: namely, we just sum up these scaled probabilities over all sample points that lie in both A and B:
$ PP[A|B] = sum_(omega in A inter B)PP[omega|B] = PP[A inter B]/PP[B]. $

*Definition 14.1* (Conditional Brobability). _For events $A,B subset.eq Omega$ in the same probability space such that $PP[B]>0$, the #underline("conditional probability of A given B") is_ $ PP[A|B] = PP[A inter B]/PP[B] $
