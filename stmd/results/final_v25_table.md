| Variant | train IoU | val IoU | test IoU | test ACC | test Pd | test precision | false clusters / 50 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| v24 selected (val-tuned) | 0.679 | 0.838 | 0.667 | 0.845 | 0.883 | 0.760 | 0.64 |
| v25 selected (train+val-tuned) | 0.789 | 0.837 | 0.813 | 0.934 | 0.902 | 0.862 | 1.47 |
| v25 without glare adaptation | 0.676 | 0.837 | 0.720 | 0.934 | 0.902 | 0.759 | 1.48 |
| v25 without noise adaptation | 0.777 | 0.826 | 0.816 | 0.917 | 0.894 | 0.881 | 1.34 |

test_000.npz  IoU=0.940 ACC=0.972 Pd=0.962 prec=0.966 fc/w=0.50
test_001.npz  IoU=0.932 ACC=0.989 Pd=0.972 prec=0.943 fc/w=0.33
test_002.npz  IoU=0.912 ACC=0.953 Pd=0.934 prec=0.955 fc/w=0.43
test_003.npz  IoU=0.680 ACC=0.957 Pd=0.953 prec=0.702 fc/w=0.84
test_004.npz  IoU=0.749 ACC=0.982 Pd=0.980 prec=0.760 fc/w=2.96
test_005.npz  IoU=0.973 ACC=0.989 Pd=0.986 prec=0.984 fc/w=0.27
test_006.npz  IoU=0.887 ACC=0.959 Pd=0.966 prec=0.922 fc/w=1.07
test_007.npz  IoU=0.880 ACC=0.969 Pd=0.942 prec=0.906 fc/w=0.95
test_008.npz  IoU=0.520 ACC=0.938 Pd=0.905 prec=0.539 fc/w=2.32
test_009.npz  IoU=0.846 ACC=0.945 Pd=0.928 prec=0.890 fc/w=1.62
test_010.npz  IoU=0.906 ACC=0.934 Pd=0.868 prec=0.968 fc/w=0.50
test_011.npz  IoU=0.851 ACC=0.914 Pd=0.865 prec=0.925 fc/w=0.96
test_012.npz  IoU=0.896 ACC=0.923 Pd=0.867 prec=0.968 fc/w=0.38
test_013.npz  IoU=0.945 ACC=0.957 Pd=0.899 prec=0.987 fc/w=0.35
test_014.npz  IoU=0.905 ACC=0.943 Pd=0.887 prec=0.958 fc/w=0.77
test_015.npz  IoU=0.810 ACC=0.903 Pd=0.869 prec=0.887 fc/w=0.33
test_016.npz  IoU=0.829 ACC=0.904 Pd=0.926 prec=0.908 fc/w=0.97
test_017.npz  IoU=0.950 ACC=0.966 Pd=0.976 prec=0.982 fc/w=0.78
test_018.npz  IoU=0.919 ACC=0.940 Pd=0.932 prec=0.977 fc/w=0.89
test_019.npz  IoU=0.880 ACC=0.890 Pd=0.755 prec=0.987 fc/w=0.16
test_020.npz  IoU=0.916 ACC=0.937 Pd=0.900 prec=0.976 fc/w=0.22
test_021.npz  IoU=0.946 ACC=0.957 Pd=0.925 prec=0.989 fc/w=0.18
test_022.npz  IoU=0.505 ACC=0.858 Pd=0.782 prec=0.552 fc/w=10.50
test_023.npz  IoU=0.592 ACC=0.816 Pd=0.833 prec=0.683 fc/w=6.36
