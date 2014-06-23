{make_esc} = require 'iced-error'
btcjs = require 'keybase-bitcoinjs-lib'
merkle = require 'merkle-tree'
{armor} = require 'pgp-utils'
{bufeq_secure,streq_secure} = require('iced-utils').util



#=============================================================================================

exports.Blockchain = class Blockchain extends merkle.Base

  #--------------------------------

  constructor : ({@req, @username, @address, @log}) ->
    @address or= "1HUCBSJeHnkhzrVKVjaVmWg2QtZS1mdfaz"
    # We can use the merkle class with the default parameters....
    super {}

  #--------------------------------

  blockr_req : ({endpoint, qs}, cb) ->
    url = "https://btc.blockr.io/api/v1/#{endpoint}"
    await @req { url, qs }, defer err, res, json
    if err? then # noop
    else if (s = json.status) isnt "success" then err = new Error "Bad status code: #{s}"
    cb err, json

  #--------------------------------

  lookup_last_tx_from_addr_blockr_io : (cb) ->
    endpoint = "address/txs/#{@address}"
    await @blockr_req { endpoint }, defer err, json
    err = if err? then err
    else if ((a = json?.data?.address) isnt (b = @address))
      new Error "Got wrong address: #{a} != #{b}"
    else if not (v = json.data.txs)?
      new Error "No transactions found"
    else
      for tx in v when (tx.amount < 0)
        @txid = tx.tx
        break
      if not @txid
        new Error "No transaction found from #{@address}; something is up!"
      else
        @log?.info "Most recent TX from #{@address} is #{@txid}"
        null
    cb err

  #--------------------------------

  lookup_tx_blockr_io : (cb) ->
    endpoint = "tx/info/#{@txid}"
    await @blockr_req { endpoint }, defer err, json
    err = if err? then err
    else if ((t = json?.data?.tx) isnt @txid) 
      new Error "Got wrong transaction: #{t} != #{@txid}"
    else if not(v = json.data.vouts)? or (v.length isnt 1)
      new Error "Got a weird transaction back from blockr.io"
    else 
      @to_addr = v[0].address
      @log?.info "Got BTC to address: #{@to_addr}"
      null
    cb err

  #--------------------------------

  lookup_btc_blockr_io : (cb) ->
    esc = make_esc cb, "Blockchain::lookup_btc_blockr"
    await @lookup_last_tx_from_addr_blockr_io esc defer()
    await @lookup_tx_blockr_io esc defer()
    cb null

  #--------------------------------

  lookup_btc_blockchain_info : (cb) ->
    url = "https://blockchain.info/address/#{@address}"
    await @req { url, qs : { format : 'json', cors : 'true'} }, defer err, res, json
    unless err?
      # There might be transactions sent TO our special address,
      # so we have to skip over those to the first FROM transaction
      for tx in json.txs when (tx.inputs[0]?.prev_out?.addr is @address)
        @to_addr = tx.out[0].addr
        break
      if @to_addr?
        @log?.info "Got BTC to address: #{@to_addr}"
      else
        err = new Error "Didn't find any announcements from #{@address}; something is up!"

    cb err

  #--------------------------------

  translate_address : (cb) ->
    err = null
    try
      {hash,version} = btcjs.Address.fromBase58Check(@to_addr)
      if version isnt btcjs.networks.bitcoin.pubKeyHash
        err = new Error "Bad address #{@to_addr}; wasn't BTC"
      else
        @to_addr_hash = hash
        @log?.info " to hash -> #{hash.toString('hex')}"
    catch e
      err = new Error "Bad address #{@to_addr}: #{e.message}"
    cb err

  #--------------------------------

  kburl : (e) -> "https://keybase.io/_/api/1.0/#{e}.json"

  #--------------------------------

  lookup_verify_merkle_root : (cb) ->
    esc = make_esc cb, "Blockchain::lookup_verify_merkle_root"
    url = @kburl "merkle/root"
    hash160 = @to_addr_hash.toString 'hex'
    await @req { url, qs : { hash160 } }, defer err, res, body
    if err? then # noop
    else if not (sig = body.sig)?
      err = new Error "No 'sig' field found in keybase root"
    else
      [err,m] = armor.decode(sig)
      if not err?
        h2 = btcjs.crypto.hash160(m.body)
        # Secure buffer comparison isn't really needed here, but why not.
        if not bufeq_secure h2, @to_addr_hash
          err = new Error 'hash mismatch at root'
        else if not (x = m.body.toString('utf8').match /(\{"body":.*?"signature"\})/)
          err = new Error "Can't scrape a JSON body out of the PGP signature"
        else
          try
            js = JSON.parse x[1]
            unless (@root_hash = js.body?.root)?
              err = new Error "Didn't find a root hash"
          catch e
            err = new Error "Can't JSON parse payload: #{e.message}"
    cb err

  #--------------------------------

  hash_fn : (s) -> btcjs.crypto.sha512(s).toString('hex')

  #--------------------------------

  lookup_root : (cb) ->
    cb null, @root_hash

  #--------------------------------

  lookup_node : ({key}, cb) ->
    @log?.info "Lookup merkle node #{key}"
    url = @kburl "merkle/block"
    await @req { url, qs : {hash : key }}, defer err, res, json
    if err? then # noop
    else if (n = json.status.name) isnt 'OK' then err = new Error "API error: #{n}"
    else if not (node = json.value)? then err = new Error "bad block returned: #{key}"
    cb err, node

  #--------------------------------

  lookup_userid : (cb) ->
    @log?.debug "+ lookup userid #{@username}"
    url = @kburl "user/lookup"
    await @req { url, qs : { @username } }, defer err, res, json
    err = if err? then err
    else if (n = json.status.name) isnt 'OK' then new Error "API error: #{n}"
    else if not (@uid = json.them.id)? then new Error "bad user object; no UID"
    else null
    @log?.info "Map: #{@username} -> #{@uid}"
    @log?.debug "- lookup userid"
    cb err

  #--------------------------------

  find_in_keybase_merkle_tree : (cb) ->
    await @find { key : @uid }, defer err, @user_triple
    cb err

  #--------------------------------

  lookup_user : (cb) ->
    url = @kburl "sig/get"
    await @req { url, qs : {@uid }}, defer err, res, json
    err = if err? then err
    else if (n = json.status.name) isnt 'OK' then new Error "API error: #{n}"
    else if not (@chain = json.sigs)? then new Error "no signatures found"
    else if not (last = @chain[-1...]?[0])? then new Error "no last signature"
    else if ((a = last.payload_hash) isnt (b = @user_triple[1])) then new Error "Bad hash: #{a} != #{b}"
    else 
      @log?.info "User triple: #{JSON.stringify @user_triple}"
      null
    cb err

  #--------------------------------

  check_chain : (cb) ->
    err = null
    for link,i in @chain
      if not streq_secure(btcjs.crypto.sha256(link.payload_json).toString('hex'), link.payload_hash)
        err = new Error "hash mismatch at link #{i}"
      try
        link.payload = JSON.parse link.payload_json
        if i > 0 and not streq_secure(link.payload.prev, @chain[i-1].payload_hash)
          err = new Error "bad previous hash at link #{i}"
      catch e
        err = new Error "failed to parse link #{i}: #{e.message}"
      break if err
    unless err?
      @log?.info "Chain checked out"
    cb err

  #--------------------------------

  run : (cb) ->
    esc = make_esc cb, "Blockchain::run"
    await @lookup_btc_blockr_io esc defer()
    await @translate_address esc defer()
    await @lookup_verify_merkle_root esc defer()
    await @lookup_userid esc defer()
    await @find_in_keybase_merkle_tree esc defer()
    await @lookup_user esc defer()
    await @check_chain esc defer()
    cb null, @chain

#=============================================================================================
