"""Every word of the Mac app in six more languages (owner, 03/10). Edit the t*.py lists, then run make.py."""
from t1 import R as R1
from t2 import R as R2
from t3 import R as R3
from t4 import R as R4
from t5 import R as R5, PLIST  # noqa: F401
from t6 import R as R6
from t7 import R as R7
from t8 import R as R8
from t9 import R as R9
from t10 import R as R10

T = {}
for row in R1 + R2 + R3 + R4 + R5 + R6 + R7 + R8 + R9 + R10:
    if row[0] in T:
        raise SystemExit(f'twice: {row[0]!r}')
    T[row[0]] = row[1:]
