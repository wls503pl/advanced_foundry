'forge clean' running (wd: /home/dayda/advanced_foundry/Defi_DSC)
'forge config --json' running
'forge build --build-info --skip ./test/** ./script/** --force' running (wd: /home/dayda/advanced_foundry/Defi_DSC)
INFO:Printers:
Compiled with Foundry
Total number of contracts in source files: 3
Number of contracts in dependencies: 12
Source lines of code (SLOC) in source files: 280
Source lines of code (SLOC) in dependencies: 352
Number of  assembly lines: 0
Number of optimization issues: 1
Number of informational issues: 19
Number of low issues: 11
Number of medium issues: 5
Number of high issues: 0

ERCs: ERC20

+-----------+-------------+-------+--------------------+--------------+--------------------+
| Name      | # functions | ERCS  | ERC20 info         | Complex code | Features           |
+-----------+-------------+-------+--------------------+--------------+--------------------+
| DSC       | 40          | ERC20 | ∞ Minting          | No           |                    |
|           |             |       | Approve Race Cond. |              |                    |
|           |             |       |                    |              |                    |
| DSCEngine | 37          |       |                    | No           | Tokens interaction |
| OracleLib | 2           |       |                    | No           |                    |
+-----------+-------------+-------+--------------------+--------------+--------------------+
INFO:Slither:. analyzed (15 contracts)
