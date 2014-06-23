request = require 'request'
log = require 'iced-logger'
minimist = require 'minimist'
base = require './base'

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

class Blockchain extends base.Blockchain

  #----------------------

  constructor : (arg) ->
    arg.req = request_to_req(request)
    arg.log = log
    super arg

#=============================================================================================

exports.main = main = () ->
  argv = minimist(process.argv[2...])
  username = argv._[0]
  if not username?
    err = new Error "usage: blockchain <username>"
  else
    blockchain = new Blockchain {username }
    await blockchain.run defer err, chain
  rc = 0
  if err?
    log.error err.message
    rc = -2
  else
    console.log chain[-1...][0].payload
  process.exit rc

#=============================================================================================
