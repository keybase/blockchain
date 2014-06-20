
{make_esc} = require 'iced-error'
btcjs = require 'keybase-bitcoin-js'
merkle = require 'merkle-tree'
{armor} = require 'pgp-utils'
iutils = require('iced-util').util

#=============================================================================================

jquery_to_request = ($) ->
  ({url,qs}, cb) ->

    success = (body, status, jqXHR) -> finish true, body, jqXHR
    error   = (jqXHR, textStatus, erroThrown) -> finish false, null, jqXHR

    finish = (success, body, jqXHR) ->
      return unless (tmp = cb)?
      cb = null
      err = null
      res = {}

      if (res.statusCode = jqXHR.status) isnt 200
        err = new Error "Non-OK HTTP error: #{res.statusCode}"
        body = null
      else
        try
          body = JSON.parse body
        catch e
          err = new Error "bad json: #{e.message}"
      tmp err, res, body

    $.ajax {type : "GET", data : qs, url, success, error }

#=============================================================================================

request_to_req = (request, cb) ->
  (params, cb) ->
    params.json = true
    await request params, defer err, res, body
    if res.statusCode != 200
      err = new Error "Non-OK HTTP error: #{res.statusCode}"
      body = null
    cb err, res, body

#=============================================================================================

exports.Blockchain = class Blockchain extends merkle.Base

  #--------------------------------

  constructor : ({$, request, @username, @address}) ->
    @address or= "1HUCBSJeHnkhzrVKVjaVmWg2QtZS1mdfaz"
    @req = if $ then jquery_to_req($) else request_to_req(request)

  #--------------------------------

  lookup_btc_blockchain : (cb) ->
    url = "https://blockchain.info/address/#{@address}"
    await @req { url, qs : { format : 'json'} }, defer err, res, json
    unless err?
      # There might be transactions sent TO our special address,
      # so we have to skip over those to the first FROM transaction
      for tx in json.txs where tx.in[0].addr is @address
        @to_addr = tx.out[0].addr
        break
      unless @to_addr?
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
        if not iutils.bufeq_secure h2, @to_addr_hash
          err = new Error 'hash mismatch at root'
        else if not (x = m.body.toString('utf8').match /(\{"body":.*?"signature"\})/)
          err = new Error "Can't scrape a JSON body out of the PGP signature"
        else
          try
            js = JSON.parse x[1]
            @root_hash = js.root
          catch e
            err = new Error "Can't JSON parse payload: #{e.message}"
    cb err

  #--------------------------------

  lookup_root : (cb) ->
    cb null, @root_hash

  #--------------------------------

  lookup_node : ({key}, cb) ->
    url = @kburl "merkle/block"
    await @req { url, qs : {hash : key }}, defer err, res, json
    if err? then # noop
    else if not ( node = json.value)? then err = new Error "bad block returned: #{key}"
    cb err, node
    
  #--------------------------------

  find_in_keybase_merkle_tree : (cb) ->

  #--------------------------------

  run : (cb) ->
    esc = make_esc cb, "Blockchain::run"
    await @lookup_btc_blockchain esc defer()
    await @translate_address esc defer()
    await @lookup_verify_merkle_root esc defer()
    await @find_in_keybase_merkle_tree esc defer()
    await @lookup_user esc defer user
    cb null, user

#=============================================================================================

