#!/usr/bin/env python3
import logging
from pprint import pp, pformat

import requests

logger = logging.getLogger('test')
session = requests.Session()
session.headers.update({'Content-Type': 'application/json'})
base_url = 'http://localhost:8080/'


def try_pformat(v):
    try:
        if hasattr(v, 'json'):
            v = v.json()
        return pformat(v)
    except Exception as e:
        return str(v)


def results():
    response = session.get(base_url)
    response.raise_for_status()
    logger.info('results %s', try_pformat(response))


def place_order(
        symbol: str,
        side: str,
        direction: str,
        price: float,
        quantity: float
):
    data = {
        'symbol': symbol,
        'side': side,
        'direction': direction,
        'price': price,
        'quantity': quantity
    }
    logger.info('placing order %s', pformat(data))
    response = session.post(base_url + 'order', json=data)
    response.raise_for_status()
    logger.info('placed order %s', try_pformat(response))
    return response.json()


def init_account(balance):
    response = session.post(base_url + 'account', json={
        'wallet': [
            {'currency': 'USDT', 'balance': balance},
        ]
    })
    logger.info('init account %s', response.text)
    response.raise_for_status()


def delete_account():
    response = session.delete(base_url + 'account')
    logger.info('delete account %s', response.text)
    response.raise_for_status()


def main():
    results()
    init_account(100)
    results()
    result = place_order('BTC', 'buy', 'long', 10000, 0.09)  # it bakes 90 USD initial
    results()
    assert result['success'] == True, 'Order should be placed'
    result = place_order('BTC', 'sell', 'long', 10000, 0.09)  # it gives back 90 USD initial
    results()
    assert result['success'] == True, 'Order should be placed'
    result = place_order('ETH', 'buy', 'long', 2000, 0.1)  # it bakes 20 USD initial
    results()
    assert result['success'] == True, 'Order should be placed'
    result = place_order('BTC', 'buy', 'long', 10000, 0.09)  # it bakes 90 USD initial, but it should not be placed
    results()
    assert result['success'] == False, 'Order should not be placed'


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    main()
