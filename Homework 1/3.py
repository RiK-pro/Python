ticket = 385916
n_6 = ticket % 10
n_5 = ticket // 10 % 10
n_4 = ticket // 100 % 10
n_3 = ticket // 1000 % 10
n_2 = ticket // 10000 % 10
n_1 = ticket // 100000

if n_1+n_2+n_3 == n_4+n_5+n_6:
    print("Ваш билетик счастливый!")
else:
    print("Повезёт в другой раз!")