local checks = require('checks')
local lru = require('lru')
local mysql = require('mysql')
local log = require('log')

local field_no = {
    name = 5,
    email = 6,
    data = 8,
}
local lru_cache

-- ========================================================================= --
-- mysql section
-- ========================================================================= --
local conn

local function fetch(login) --get tuple from mysql storage if it isn't present in cache
    checks('string')

    local account = conn:execute(string.format("SELECT * FROM account WHERE login = \'%s\'", login))

    if (#account[1] == 0) then 
        return nil
    end

    account = account[1][1]
    local time = os.time()
    local tmp = {
        account.login,
        account.password,
        account.session,
        account.bucket_id,
        account.name,
        account.email,
        time,
        account.data
    }

    box.space.account:insert(tmp) --insert tuple into cache

    log.info(string.format("\'%s\' uploaded from mysql", tmp[1]))

    return tmp
end

-- ========================================================================= --
-- write behind section
-- ========================================================================= --

local write_queue = {}

local function write_behind() --update changed tuple from cache in mysql storage

    for login, _ in pairs(write_queue) do

        local account = box.space.account:get(login)
        if (account ~= nil) then
            
            
            conn:execute(string.format("REPLACE INTO account value (\'%s\', \'%s\', \'%d\', \'%d\', \'%s\', \'%s\', \'%s\')", 
                account[1], 
                account[2], 
                account[3], 
                account[4], 
                account[5], 
                account[6], 
                account[8]
            ))

            log.info(string.format("\'%s\' updated in mysql", account[1]))
            
        end
    end

    write_queue = {}
    return true
end

local function set_to_update(login) --set tuple to be updated in mysql
    checks('string')

    if write_queue[login] == nil then
        write_queue[login] = true
    end

    return true
end

-- ========================================================================= --
-- update section
-- ========================================================================= --

local update_period = 5
local last_update = os.time()
local cache_size = 2

local function update_storage() --update mysql storage periodically
    if(os.time() - last_update) < update_period then
        return false
    end

    write_behind()
    last_update = os.time()
    return true
end

local function update_cache(login) --remove least recently used tuples from cache
    checks('string')

    local result, err = lru_cache:touch(login)

    if err ~= nil then
        return nil, err
    end

    if result == true then 
        return true
    end
    log.info(string.format("Removing \'%s\' from cache", result))
    box.space.account:delete(result)

    return true
end

-- ========================================================================= --
-- supporting functions
-- ========================================================================= --

local function verify_session(account) --verify if account exists and session is up

    if account == nil then --if account is not found
        print(account)
        return false, nil
    end

    if account[3] == 1 then --if session is up return true
        return true
    end

    return false, false
end

-- ========================================================================= --
-- storage functions
-- ========================================================================= --

local function init_spaces()
    local account = box.schema.space.create(
        'account',
        {
            format = {
                {'login', 'string'},
                {'password', 'string'},
                {'session', 'number'},
                {'bucket_id', 'unsigned'},
                {'name', 'string'},
                {'email', 'string'},
                {'last_action', 'unsigned'},
                {'data', 'string'}
            },
            if_not_exists = true,
            engine = 'memtx',
            temporary = true,
        }
    )

    account:create_index('login', {
        parts = {'login'},
        if_not_exists = true,
    })

    account:create_index('bucket_id', {
        parts = {'bucket_id'},
        unique = false,
        if_not_exists = true,
    })

    conn = mysql.connect({
        host = '127.0.0.1', 
        user = 'root', 
        password = '1234', 
        db = 'tarantool'
    })

    lru_cache = lru.new(cache_size) --least recently used cache
    for k, account in box.space.account:pairs() do --recover lru cache 
        update_cache(account[1])
    end
end

local function account_add(account)
    update_storage()
    local tmp = box.space.account:get(account.login) --check if account already exists
    if tmp == nil then
        tmp = fetch(account.login)
    end

    if tmp ~= nil then
        return false
    end

    box.space.account:insert({
        account.login,
        account.password,
        1,
        account.bucket_id,
        account.name,
        account.email,
        os.time(),
        account.data
    })

    update_cache(account.login)
    set_to_update(account.login)

    return true
end

local function account_sign_in(login, password)
    checks('string', 'string')
    update_storage()

    local account = box.space.account:get(login) --check if account exists, return nil if not
    if account == nil then
        account = fetch(login) --check additional storage if it isn't present in cache
    end

    if account == nil then  
        return nil
    end

    if password ~= account[2] then --verify password, return false if password is wrong
        return false
    end

    box.space.account:update({ login } , {
        {'=', 3, 1},
        {'=', 7, os.time()} --update last action timestamp
    })
    update_cache(login) --update account's position in lru cache
    set_to_update(login) --set account to be updated in vinyl storage

    return true
end

local function account_sign_out(login)
    checks('string')
    update_storage()

    local account = box.space.account:get(login) --check if account exists, return nil if not
    if account == nil then
        account = fetch(login) --check additional storage if it isn't present in cache
    end

    local valid, err = verify_session(account)
    if not valid then
        return err
    end

    box.space.account:update({ login } , {
        {'=', 3, -1},
        {'=', 7, os.time()}
    })
    update_cache(login) --update account's position in lru cache
    set_to_update(login) --set account to be updated in vinyl storage

    return true
end

local function account_update(login, field, value)
    update_storage()

    local field_n = field_no[field] --check if requested field is valid
    if field_n == nil then 
        return -1
    end

    local account = box.space.account:get(login) --check if account exists, return nil if not
    if account == nil then
        account = fetch(login) --check additional storage if it isn't present in cache
    end

    local valid, err = verify_session(account)
    if not valid then
        return err
    end

    box.space.account:update({ login }, {
        { '=', field_n, value},
        { '=', 7, os.time()}
    })
    update_cache(login) --update account's position in lru cache
    set_to_update(login) --set account to be updated in mysql storage

    return true
end

local function account_get(login, field)
    checks('string', 'string')
    update_storage()

    local field_n = field_no[field] --check if requested field is valid
    if field_n == nil then 
        return -1
    end

    local account = box.space.account:get(login) --check if account exists, return nil if not
    if account == nil then
        account = fetch(login) --check additional storage if it isn't present in cache
    end

    local valid, err = verify_session(account)
    if not valid then
        return err
    end

    box.space.account:update({login}, {
        {'=', 7, os.time()}
    })
    
    update_cache(login) --update account's position in lru cache
    return account[field_n]
end

local function account_delete(login)
    checks('string')
    update_storage()
    print(login)
    
    local account = box.space.account:get(login) --check if account exists, return nil if not
    if account == nil then
        account = fetch(login) --check additional storage if it isn't present in cache
    end
   
    local valid, err = verify_session(account)
    if valid ~= true then
        return err
    end

    conn:execute(string.format("DELETE FROM account WHERE login = \'%s\'", login ))
    box.space.account:delete(login)


    lru_cache:delete(login)
    local account = box.space.account:delete(login)
    return true
end

local function init(opts)
    if opts.is_master then

        init_spaces()

        box.schema.func.create('account_add', {if_not_exists = true})
        box.schema.func.create('account_sign_in', {if_not_exists = true})
        box.schema.func.create('account_sign_out', {if_not_exists = true})
        box.schema.func.create('account_delete', {if_not_exists = true})
        box.schema.func.create('account_update', {if_not_exists = true})
        box.schema.func.create('account_get', {if_not_exists = true})

        box.schema.role.grant('public', 'execute', 'function', 'account_add', {if_not_exists = true})
        box.schema.role.grant('public', 'execute', 'function', 'account_sign_in', {if_not_exists = true})
        box.schema.role.grant('public', 'execute', 'function', 'account_sign_out', {if_not_exists = true})
        box.schema.role.grant('public', 'execute', 'function', 'account_delete', {if_not_exists = true})
        box.schema.role.grant('public', 'execute', 'function', 'account_update', {if_not_exists = true})
        box.schema.role.grant('public', 'execute', 'function', 'account_get', {if_not_exists = true})

    end

    rawset(_G, 'account_add', account_add)
    rawset(_G, 'account_sign_in', account_sign_in)
    rawset(_G, 'account_sign_out', account_sign_out)
    rawset(_G, 'account_get', account_get)
    rawset(_G, 'account_delete', account_delete)
    rawset(_G, 'account_update', account_update)

    return true
end

return {
    role_name = 'cache_mysql',
    init = init,
    dependencies = {
        'cartridge.roles.vshard-storage',
    },
    utils = {
        write_behind = write_behind,
        set_to_update = set_to_update,
        update_storage = update_storage,
        update_cache = update_cache,
        fetch = fetch,
        verify_session = verify_session,
        account_add = account_add, 
        account_update = account_update,
        account_delete = account_delete, 
        account_get = account_get,
        account_sign_in = account_sign_in, 
        account_sign_out = account_sign_out,
    }
}
