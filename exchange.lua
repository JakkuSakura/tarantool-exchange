#!/usr/bin/env tarantool
local box = require('box')
local server = require('http.server')
local log = require('log')
-- we could use log.info but there are too many prints. a bit late to change

--------- helper functions ------------
local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k, v in pairs(o) do
            if type(k) ~= 'number' then k = '"' .. k .. '"' end
            s = s .. '[' .. k .. '] = ' .. dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(o)
    end
end
local function is_zero(v)
    return math.abs(v) < 1e-6
end
--------- Constants -----------
local default_account = 1
local default_currency = 'USDT'
local leverage = 10
local minimal_margin_ratio = 1.0 / leverage

local BUY = 'buy'
local SELL = 'sell'
local LONG = 'long'
local SHORT = 'short'
--------- Data Access Layer ---------
local orders
-- Order: order_id, symbol, price, quantity
local function configure_orders()
    box.schema.space.create('orders')
    orders = box.space.orders
    orders:format({
        { name = 'order_id',  type = 'unsigned' },
        { name = 'symbol',    type = 'string' },
        { name = 'account',   type = 'unsigned' },
        { name = 'side',      type = 'string' }, -- buy or sell
        { name = 'direction', type = 'string' }, -- long or short
        { name = 'price',     type = 'number' },
        { name = 'quantity',  type = 'number' },
    })
    orders:create_index('primary',
        { type = 'TREE', parts = { 'order_id' } }
    )
    orders:create_index('symbol_id_index', {
        type = 'TREE',
        parts = { 'symbol', 'order_id' },
    })
    orders:create_index('account_symbol_id_index', {
        type = 'TREE',
        parts = { 'account', 'symbol', 'order_id' },
    })
end
-- Function to insert an order
local function insert_order(account, symbol, side, direction, price, quantity)
    -- Generate a unique order ID
    local order_id = orders:count() + 1
    print("Order inserting:", order_id)
    -- Insert the order
    orders:insert { order_id, symbol, account, side, direction, price, quantity }
    print("Order inserted:", order_id, symbol, account, side, direction, price, quantity)
    return order_id
end

local order_book
-- OrderBook: symbol, price
local function configure_order_book()
    box.schema.space.create('order_book')
    order_book = box.space.order_book
    order_book:format({
        { name = 'symbol', type = 'string' },
        { name = 'price',  type = 'number' }
    })
    order_book:create_index('primary',
        { type = 'TREE', parts = { 'symbol' } }
    )
end
-- Function to insert an order book entry
local function upsert_order_book(symbol, price)
    print("Order book upserting:", symbol, price)
    order_book:upsert({ symbol, price }, { { '=', 1, symbol } })
    print("Order book inserted:", symbol, price)
end

-- Function to get the best price for a symbol
local function get_best_price(symbol)
    local best_price = order_book:select(symbol, { limit = 1, iterator = 'EQ' })
    if #best_price == 0 then
        return nil
    end
    return best_price[1][2]
end

local positions
local function configure_positions()
    box.schema.space.create('positions')
    positions = box.space.positions
    positions:format({
        { name = 'account',     type = 'unsigned' },
        { name = 'symbol',      type = 'string' },
        { name = 'direction',   type = 'string' }, -- long or short
        { name = 'quantity',    type = 'number' },
        { name = 'entry_price', type = 'number' }
    })
    positions:create_index('primary',
        { type = 'TREE', parts = { 'account', 'symbol', 'direction' } }
    )
end

-- Function to insert a position
local function insert_position(account, symbol, direction, quantity, price)
    print("Position inserting:", account, symbol, direction, quantity, price)
    positions:insert { account, symbol, direction, quantity, price }
    print("Position inserted:", account, symbol, direction, quantity, price)
end

-- Function to update a position
local function add_position(account, symbol, side, direction, quantity, price)
    print("Position adding:", account, symbol, side, direction, quantity, price)
    local position = positions:select({ account, symbol, direction }, { limit = 1, iterator = 'EQ' })
    local quantity_adjusted = quantity
    if side == SELL then
        quantity_adjusted = -quantity
    end

    if #position == 0 then
        if side == SELL then
            error("Position not found, cannot sell:" .. 'account' .. account .. ' ' .. symbol .. ' ' .. direction)
        end
        insert_position(account, symbol, direction, quantity, price)
        return
    end

    position = position[1]
    print("Position found:", dump(position))
    local new_quantity = position[4] + quantity_adjusted
    if new_quantity < 0 then
        error("New position quantity cannot be negative" .. 'account' .. account .. ' ' .. symbol .. ' ' .. direction)
    end

    if new_quantity == 0 then
        positions:delete({ account, symbol, direction })
        print("Position deleted:", account, symbol, direction)
        return
    end

    local new_entry_price = (position[4] * position[5] + quantity_adjusted * price) / new_quantity

    positions:update({ account, symbol, direction }, { { '=', 4, new_quantity }, { '=', 5, new_entry_price } })
    print("Position updated:", account, symbol, direction, new_quantity, new_entry_price)
end

-- Function to get the position for a symbol
local function get_position(account, symbol, direction)
    local position = positions:select({ account, symbol, direction }, { limit = 1, iterator = 'EQ' })
    if position == nil then
        return nil
    end
    return position[3], position[4]
end

local balances
-- Wallet: currency, balance
local function configure_wallet_balance()
    box.schema.space.create('wallet_balance')
    balances = box.space.wallet_balance
    balances:format({
        { name = 'account',  type = 'unsigned' },
        { name = 'currency', type = 'string' },
        { name = 'balance',  type = 'number' }
    })
    balances:create_index('primary',
        { type = 'TREE', parts = { 'account', 'currency' } }
    )
end
local function get_balance(account, currency)
    local balance = balances:select({ account, currency }, { limit = 1, iterator = 'EQ' })
    if #balance == 0 then
        return 0.0
    end
    return balance[1][3]
end

local function init_db()
    box.cfg {
        listen = 3301,
    }
    box.once("orders", configure_orders)
    box.once("order_book", configure_order_book)
    box.once("positions", configure_positions)
    box.once("wallet_balance", configure_wallet_balance)
end

---------Business Logic Layer--------
local function biz_unrealized_pnl(account)
    local positions_data = positions:select({ account })
    local unrealized_pnl = 0
    for _, position in ipairs(positions_data) do
        --local account = position[1]
        local symbol = position[2]
        local direction = position[3]
        local quantity = position[4]
        local entry_price = position[5]
        local current_price = get_best_price(symbol)
        if current_price == nil then
            print("Failed to get current price for symbol", symbol)
            return nil
        end
        local side = 1
        if direction == SHORT then
            side = -1
        end
        print("Calculating unrealized pnl", account, symbol, direction, quantity, entry_price, current_price)
        unrealized_pnl = unrealized_pnl + side * (current_price - entry_price) * quantity
    end
    return unrealized_pnl
end

-- account equity = wallet balance + unrealized pnl
local function biz_account_equity(account)
    local wallet_balance_data = get_balance(account, default_currency)
    local unrealized_pnl = biz_unrealized_pnl(account)
    print("Calculating account equity", account, wallet_balance_data, unrealized_pnl)
    return wallet_balance_data + unrealized_pnl
end
local function biz_position_notional_sum(account)
    print("Calculating position notional sum", account)
    local positions_data = positions:select({ account })
    local total_position_notional = 0
    for _, position in ipairs(positions_data) do
        --local account = position[1]
        local symbol = position[2]
        --local direction = position[3]
        local quantity = position[4]
        local current_price = get_best_price(symbol)
        if current_price == nil then
            return nil
        end
        total_position_notional = total_position_notional + current_price * quantity
    end
    print("Position notional sum", account, total_position_notional)
    return total_position_notional
end
-- account margin ratio = account equity / total position notional
local function biz_account_margin_ratio(account)
    print("Calculating margin ratio", account)
    local account_equity = biz_account_equity(account)
    local positions_data = biz_position_notional_sum(account)
    if is_zero(positions_data) then
        return 1.0
    end
    local margin_ratio = account_equity / positions_data
    print("Margin ratio", account, account_equity, positions_data, margin_ratio)
    return margin_ratio
end

local function biz_place_order(account, symbol, side, direction, price, quantity)
    print("Place order:", account, symbol, side, direction, price, quantity)
    print('Start transaction')
    box.begin()
    -- Insert the order
    local order_id = insert_order(account, symbol, side, direction, price, quantity)
    -- Update the order book. This step effectly update the price. not accurate but ok for the demo purpose
    upsert_order_book(symbol, price)
    -- Update the positions
    local success, result = pcall(add_position, account, symbol, side, direction, quantity, price)
    if success == false then
        print('Rollback transaction', result)
        box.rollback()
        return nil
    end

    local margin_ratio = biz_account_margin_ratio(account)
    if margin_ratio <= minimal_margin_ratio then
        print('Rollback transaction due to margin ratio', margin_ratio)
        box.rollback()
        return nil
    end
    print('Commit transaction')
    box.commit()
    return order_id
end

local function handle_mainpage(self)
    local account = default_account
    -- show orderbook
    local order_book_data = order_book:select({}, { limit = 10, iterator = 'ALL' })
    ---- show positions
    local positions_data = positions:select({ account })
    ---- show order history
    local orders_data = orders:select({ account })
    ---- show account balance
    local wallet_balance_data = balances:select({ account })
    ---- show account equity
    local account_equity = biz_account_equity(account)
    ---- show account margin ratio
    local account_margin_ratio = biz_account_margin_ratio(account)
    return self:render {
        status = 200,
        json = {
            order_book = order_book_data,
            orders = orders_data,
            positions = positions_data,
            wallet_balance = wallet_balance_data,
            account_equity = account_equity,
            account_margin_ratio = account_margin_ratio
        }
    }
end

local function handle_place_order(req)
    -- Read the JSON body from the request
    local params = req:json()

    -- Extract parameters
    local account = default_account
    local symbol = params.symbol
    local side = params.side
    local direction = params.direction
    local price = params.price
    local quantity = params.quantity


    -- Insert the order into the orders space
    local order_id = biz_place_order(account, symbol, side, direction, price, quantity)
    if order_id == nil then
        return req:render {
            status = 400,
            json = {
                success = false,
                message = "Order rejected"
            }
        }
    end
    -- Respond with the inserted order details
    return req:render {
        status = 201,
        json = {
            success = true,
            message = "Order created",
            order_id = order_id,
            symbol = symbol,
            price = price,
            quantity = quantity
        }
    }
end

local function handle_init_account(req)
    local params = req:json()
    local wallet = params.wallet
    local account = default_account
    for _, node in ipairs(wallet) do
        local currency = node.currency
        local balance = node.balance
        balances:insert({ account, currency, balance })
    end
end

--local function handle_delete_account(req)
--    local account = default_account
--    balances:delete({ account })
--    positions:delete({ account })
--    orders:delete({ account })
--end


local function serve_http()
    local m_server = server.new(nil, 8080, { charset = "utf8" })
    m_server:route({ method = 'GET', path = '/' }, handle_mainpage)
    m_server:route({ method = 'POST', path = '/order' }, handle_place_order)
    m_server:route({ method = 'POST', path = '/account' }, handle_init_account)
    --m_server:route({ method = 'DELETE', path = '/account' }, handle_delete_account)
    m_server:start()
end


init_db()
serve_http()
