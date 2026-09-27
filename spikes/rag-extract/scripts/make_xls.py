#!/usr/bin/env python3
"""A 5,000-row BIFF8 .xls with Cyrillic shared strings (long enough to force
SST CONTINUE records), numbers, dates and booleans -- via xlwt (sample
generation only; the extractor is Swift). usage: make_xls.py OUT.xls"""
import datetime
import sys

import xlwt

wb = xlwt.Workbook(encoding="utf-8")
ws = wb.add_sheet("Поставки")
date = xlwt.easyxf(num_format_str="DD.MM.YYYY")
money = xlwt.easyxf(num_format_str="#,##0.00")
header = ["№", "Товар", "Город", "Количество", "Цена", "Дата поставки", "Оплачено", "Комментарий"]
for c, h in enumerate(header):
    ws.write(0, c, h)
products = ["Кирпич керамический", "Цемент М500", "Песок речной", "Щебень гранитный", "Brick, red", "Арматура А500С"]
cities = ["Москва", "Санкт-Петербург", "Казань", "Новосибирск", "London"]
for r in range(1, 5001):
    ws.write(r, 0, r)
    ws.write(r, 1, products[r % len(products)])
    ws.write(r, 2, cities[r % len(cities)])
    ws.write(r, 3, r * 3 % 997)
    ws.write(r, 4, (r % 1000) * 1.25 + 0.5, money)
    ws.write(r, 5, datetime.date(2024, 1, 1) + datetime.timedelta(days=r % 700), date)
    ws.write(r, 6, r % 3 == 0)
    # unique long strings -> big SST split over CONTINUE records
    ws.write(r, 7, f"Примечание к строке {r}: доставка до склада, разгрузка силами поставщика, счёт {r * 7}")
ws2 = wb.add_sheet("Second")
ws2.write(0, 0, "Formula result")
ws2.write(1, 0, xlwt.Formula("1+2"))
wb.save(sys.argv[1])
