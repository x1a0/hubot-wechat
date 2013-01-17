Http       = require 'http'
Url        = require 'url'
Crypto     = require 'crypto'
Express    = require 'express'
XmlBuilder = require 'xmlbuilder'
XmlStream  = require 'xml-stream'

# Hubot dependencies
{Adapter, TextMessage} = require 'hubot'

class WeChat extends Adapter
    validate: ->
        throw "Environment variable 'HUBOT_WECHAT_HOSTNAME' is missing" if not process.env.HUBOT_WECHAT_HOSTNAME?

        @settings =
            hostname: process.env.HUBOT_WECHAT_HOSTNAME
            port: process.env.HUBOT_WECHAT_PORT || 80
            path: process.env.HUBOT_WECHAT_PATH || '/wechat'
            media_path: process.env.HUBOT_WECHAT_MEDIA_PATH || '/wechat/media'

    run: ->
        @validate()
        @express = Express()
        @express.get @settings.path, (req, res) =>
            parsed = Url.parse req.url, true
            signature = parsed['query']['signature']
            timestamp = parsed['query']['timestamp']
            nonce     = parsed['query']['nonce']
            echostr   = parsed['query']['echostr']
            token     = process.env.HUBOT_WECHAT_TOKEN

            shasum = Crypto.createHash 'sha1'
            shasum.update [token, timestamp, nonce].sort().join('')
            expected = shasum.digest('hex')

            if signature is expected
                res.end echostr
            else
                res.end ''

        # redirect media URL
        @express.get "#{@settings.media_path}/:url", (req, res) =>
            url = req.params.url
            res.redirect url, 301
            return

            # Disabled - proxy data
            request = Http.get url, (media_res) =>
                media_res.on 'data', (chunk) =>
                    res.write chunk
                media_res.on 'end', () =>
                    res.end()

        @express.post @settings.path, (req, res) =>
            type = null
            from = null
            to = null
            timestamp = null
            content = null
            req.setEncoding 'utf8'

            xml = new XmlStream req

            xml.on 'updateElement: MsgType', (element) =>
                type = element['$text']

            xml.on 'updateElement: FromUserName', (element) =>
                from = element['$text']

            xml.on 'updateElement: ToUserName', (element) =>
                to = element['$text']

            xml.on 'updateElement: Content', (element) =>
                content = element['$text']

            xml.on 'end', () =>
                user = @userForId from
                message = new TextMessage user, content

                # put extra data into message
                message.extra =
                    http_res  : res
                    to        : to
                    timestamp : timestamp
                    type      : 'text'

                @robot.logger.info "Receive message: #{content}"
                @receive message

        # For now (15th Jan 2013) WeChat only talks to port 80. If set this to
        # another port there has to be a HTTP reverse proxy. e.g. Nginx.
        @express.listen @settings.port
        @emit 'connected'

    reply: (envelope, strings...) ->
        strings = strings.map (s) -> "#{envelope.user.name}: #{s}"
        @send envelope, strings...

    send: (envelope, strings...) ->
        data = ''
        data += str for str in strings

        user = envelope.user
        message = envelope.message

        xml = XmlBuilder.create 'xml'
        xml.ele 'ToUserName', user.id
        xml.ele 'FromUserName', message.extra.to
        xml.ele 'CreateTime', Math.floor(Date.now() / 1000).toString()

        # Check if message contains image urls.
        pattern = /http(s?):\/\/.*?\.(png|jpg|jpeg|gif)/i
        match = data.match pattern
        if match
            url = "http://#{@settings.hostname}#{@settings.media_path}/#{encodeURIComponent match[0]}"
            xml.ele 'MsgType', 'news'
            xml.ele 'ArticleCount', '1'
            item = xml.ele('Articles').ele('item')
            item.ele 'PicUrl', url
            item.ele 'Url', url
            item.ele 'Title', ''
            item.ele 'Description', data
        else
            xml.ele 'Content', data
            xml.ele 'MsgType', 'text'

        xml.end { pretty: true }

        message.extra.http_res.end xml.toString 'utf8'

exports.use = (robot) ->
  new WeChat robot
