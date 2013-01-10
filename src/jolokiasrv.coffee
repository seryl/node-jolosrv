Jolokia = require 'jolokia-client'
async = require 'async'
Gmetric = require 'gmetric'

Config = require './config'

###*
 * Jolokia server client wrapper.
###
class JolokiaSrv
  constructor: (@interval) ->
    @interval or= 15
    @jclients = new Object()
    @gmond_interval_id = null
    @config = Config.get()

  ###*
   * Add a new jolokia lookup client into the hash.
   * @param  {String}  (name) The name of the client to add
   * @param  {String}  (url) The jolokia url for the client
   * @param  {Object}  (attributes) The attributes to lookup for the client
   * @return {Object}  The jolokia client that was added
  ###
  add_client: (name, url, attributes) =>
    @jclients[name] =
      client: new Jolokia(url)
      attributes: attributes || new Object()
      cache: new Object()

  ###*
   * Cleanup attributes for a client before they are cached for fast lookups.
   * @param {Object} (attributes) The metrics attributes for a given client
   * @param {Function} (fn) The callback function
  ###
  convert_attribs_to_hash: (attributes, fn) =>
    async.reduce attributes, new Object()
    , (mbean_memo, mbean_attr, mbean_cb) =>
      mbean_memo[mbean_attr.mbean] ||= new Object()

      # Handle Attributes
      async.reduce mbean_attr.attributes, mbean_memo[mbean_attr.mbean]
      , (a_memo, a_attr, a_cb) =>
        a_memo[a_attr.name] ||= new Object()
        if a_attr.hasOwnProperty('graph') and
        Object.keys(a_attr.graph).length > 0
          a_memo[a_attr.name].graph = a_attr.graph

        if a_attr.hasOwnProperty('value')
          a_memo[a_attr.name].value = a_attr.value

        # Handle composites
        if a_attr.hasOwnProperty('composites') and
        a_attr.composites.length > 0
          async.forEach a_attr.composites
          , (cmp_attr, cmp_cb) =>
            a_memo[a_attr.name][cmp_attr.name] ||= new Object()
            if cmp_attr.hasOwnProperty('graph') and
            Object.keys(cmp_attr.graph).length > 0
              a_memo[a_attr.name][cmp_attr.name].graph = cmp_attr.graph

            if cmp_attr.hasOwnProperty('value')
              a_memo[a_attr.name][cmp_attr.name].value = cmp_attr.value
            cmp_cb(null)
          , (cmp_err) =>
            a_cb(null, a_memo)
        else
          a_cb(null, a_memo)

      , (a_err, a_results) =>
        mbean_cb(a_err, mbean_memo)

    , (err, results) =>
      fn(err, results)

  ###*
   * Removes all jolokia attributes for the given client.
   * @param {String} (name) The name of the client to remove attributes of
  ###
  remove_attributes: (name) =>
    return unless @jclients[name]
    return unless Object.keys(@jclients[name]['attributes']).length > 0
    for key in Object.keys(@jclients[name]['attributes'])
      delete @jclients[name]['attributes'][key]

  ###*
   * List the current jolokia clients.
   * @return {Array} The list of current clients
  ###
  list_clients: =>
    Object.keys(@jclients)

  ###*
   * Removes a jolokia client from the hash.
   * @param  {String} (name) The name of the client to remove
   * @return {String} The list of remaining clients
  ###
  remove_client: (name) =>
    delete @jclients[name]
    @list_clients()

  ###*
   * Returns detailed information for the given client.
   * @param  {String} (name) The name of the client to lookup
   * @return {Object} The hash representing the client info
  ###
  info_client: (name) =>
    client = @jclients[name]
    if client
      client['attributes']
    else
      null

  ###*
   * Generates a query information for the JMX update.
   * @param  {Object} (attributes) The detailed information for a client
   * @return {Array}  The list of info objects
  ###
  generate_query_info: (attributes) =>
    query_info = []
    unless attributes == null
      for m in attributes
        for attr in m.attributes
          if attr.hasOwnProperty('graph') then g = attr.graph else g = {}
          if attr.hasOwnProperty('composites') then c = attr.composites
          else c = []
          query_info.push
            mbean: m.mbean
            attribute: attr.name
            graph: g
            composites: c
      return query_info

  ###*
   * Generates a query array for the jolokia client.
   * @param  {Object} (query_info) The query info for a client
   * @return {Array}  The list of items to query
  ###
  generate_client_query: (query_info) =>
    query = []
    for q in query_info
      query.push({ mbean: q.mbean, attribute: q.attribute })
    return query

  ###*
   * Takes the query_info and response objects and gets the proper result set.
   * @param {String} (name) The name of the client to query
   * @param {Object} (attrs) The metrics attributes for a client
   * @param {Object} (response) The query response from jolokia
   * @param {Function} (fn) The callback function
  ###
  lookup_attribute_or_composites: (name, attrs, response, fn) =>
    @convert_attribs_to_hash attrs, (h_err, hattribs) =>
      handle_response_obj = (item, cb) =>
        mbean = item.request.mbean
        attribute = item.request.attribute
        value = item.value

        retrieve_composite_value = (input) =>
          if typeof input == 'string'
            input = input.split('|')
          return recursive_get_val(value, input)

        recursive_get_val = (walk, list) =>
          if list.length > 1
            next = list.shift()
            return recursive_get_val(walk[next], list)
          else
            return walk[list]

        # Add the top-level value if it is a simple k/v
        if hattribs[mbean][attribute].hasOwnProperty('graph') and
        Object.keys(hattribs[mbean][attribute].graph).length > 0
          hattribs[mbean][attribute].value = value

        # For each key that isn't graph or value, get their values
        keys = (k for k in Object.keys(hattribs[mbean][attribute]) when \
        k != 'graph' and k!= 'value')
        for k in keys
          hattribs[mbean][attribute][k].value = retrieve_composite_value(k)
        cb(null)

      async.forEach response, handle_response_obj, (err) =>
        @jclients[name].cache = hattribs
        fn(null, hattribs)

  ###*
   * Queries jolokia mbeans for a given client and updates their values.
   * @param {String} (name) The name of the client to query
   * @param {Function} (fn) The callback function
  ###
  query_jolokia: (name, fn) =>
    attrs = @info_client(name)
    query_info = @generate_query_info(attrs)
    query = @generate_client_query(query_info)
    if query == [] then return null
    client = @jclients[name].client
    client.read query, (response) =>
      @lookup_attribute_or_composites(name, attrs, response, fn)

  ###*
   * Returns detailed information for all clients.
   * @return {Object} The hash representing the all client info
  ###
  info_all_clients: () =>
    clients = new Object()
    for key in Object.keys(@jclients)
      clients[key] = @info_client(key)
    clients

  ###*
   * Starts up the gmond metric spooler.
  ###
  start_gmond: (host, port, spoof) =>
    return unless @interval
    if @gmond_interval_id then stop_gmond()
    @gmond_interval_id = setInterval () =>
      @submit_metrics()
    , @interval

  ###*
   * Stops the gmond metric spooler.
  ###
  stop_gmond: () =>
    if @gmond_interval_id
      clearInterval(@gmond_interval_id)
      @gmond_interval_id = null

  ###*
   * Submits gmetric data to the gmond target.
   * ex:  { host:  'exhost.domain.com',
   *        name:  'mygraphname',
   *        units: 'percentage', 
   *        type:  'int32',
   *        slope: 'both',
   *        tmax:   60,
   *        dmax:   120,
   *        group:  'mygraph_group' }
  ###
  submit_metrics: =>
    clients = @info_all_clients()

module.exports = JolokiaSrv
