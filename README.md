# Tarantool Exchange

This is an simple example of a cross margin exchange using tarantool

## Notes

1. the exchange is perpetual futures exchange, with always 0 funding rate and 0 fees
2. the exchange only supports hedged mode and cross margin
3. verification of the user input is not done for simplicity
4. leaves an API to help testing
5. each user's asset is isolated
6. only one default user is supported
7. This implementation focus on demostrating tarantool and margin calculation. Thus order matching is simplified by
   assuming the bid/ask spread is 0, user can always influence the market and get wanted
   price

## Setup

Run the following command to install the dependencies

```bash
brew install tarantool tt
tt rocks install http
tt init
```

Then run the following command to start the server

```bash
./exchange.lua
```

If you want to run the tests, run the following command

```bash
./test.py
```

You can cleanup the database by

```bash
./clean.sh
```

## Breakdown and Thoughts

In reality, designing and implementation an exchange is a huge project.
For sake of this assignment, I have to make some assumptions

The tool chosen is tarantool, which is a in-memory database with lua support.
It's easy to use, just that tutorial is fragmented and not easy to find. Luckily, I quickly studied all the pieces I
need to build this exchange.

The main activity for an exchange is order placement. When an user places an order, the following things happen

1. (validation) the request format is valid and conditions are met
2. (pre-check) the order went through validation to check if the user has enough balance/collateral
3. (locking) locks the user's balance(for SPOT)/initial margin(for FUTURES)
4. (taker order matching) the order is matched against the order book as taker order
5. (maker order matching) if the order has remaining quantity, it's put into the order book as maker order
6. (clearance) according to the match engine output, reflect initial margin, maintenance margin and position
7. (liquidation) check if the user equity exceeds the liquidation threshold

The headache part is maker order matching, which is async by nature, so the pre-check and locking are necessary.

However, the requires emphasize on margin calculation and implies taker-only, we could simplify the flow a bit, by only
supporting taker order:

Start the transaction:

1. (validation) the request format is valid and conditions are met
2. (taker order matching) the order is matched against the order book as taker order
3. (clearance) according to the match engine output, reflect initial margin, maintenance margin, position, pnl, margin
   ratio

If anything went wrong, rollback the transaction.

It's still possible to support maker order, we need to implement a real price-time priority matching engine.
The notional value of a position is the same as the order, so it's similar to calculate the margin afterwards without
affecting the orderbook.

The testing are written in Python because I'm more familial with Python requests library. 




