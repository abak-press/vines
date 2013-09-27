# encoding: UTF-8

module Vines
  class Stanza
    class Presence < Stanza
      register "/presence"

      VALID_TYPES = %w[subscribe subscribed unsubscribe unsubscribed unavailable probe error].freeze
      PRIORITY = 'priority'.freeze

      VALID_TYPES.each do |type|
        define_method "#{type}?" do
          self['type'] == type
        end
      end

      def process
        stream.last_broadcast_presence = @node.clone unless validate_to
        unless self['type'].nil?
          raise StanzaErrors::BadRequest.new(self, 'modify')
        end

        dir = outbound? ? 'outbound' : 'inbound'
        method("#{dir}_broadcast_presence").call
      end

      def outbound?
        !inbound?
      end

      def inbound?
        stream.class == Vines::Stream::Server ||
        stream.class == Vines::Stream::Component
      end

      def outbound_broadcast_presence
        to = validate_to

        self['from'] = (to.nil? || !restored?) ? stream.user.jid.to_s
                                               : validate_from.to_s

        type = (self['type'] || '').strip
        initial = to.nil? && type.empty? && !stream.available?

        recipients = if to.nil?
          stream.available_subscribers
        else
          # NOTICE : Check this
          stream.user.subscribed_from?(to) ? stream.available_resources(to) : []
        end

        broadcast(recipients)
        broadcast(stream.available_resources(stream.user.jid))

        if initial
          stream.available_subscribed_to_resources.each do |recipient|
            if recipient.last_broadcast_presence
              el = recipient.last_broadcast_presence.clone
              el['to'] = stream.user.jid.to_s
              el['from'] = recipient.user.jid.to_s
              stream.write(el)
            end
          end
          stream.remote_subscribed_to_contacts.each do |contact|
            send_probe(contact.jid.bare)
          end

          # Send stanzas which was received while user was offline
          send_pending_stanzas

          # Send messages which was not marked as unread
          send_renew_messages

          stream.available!
        end

        stream.remote_subscribers(to).each do |contact|
          node = @node.clone
          node['to'] = contact.jid.bare.to_s
          router.route(node) rescue nil # ignore RemoteServerNotFound
        end
      end

      def inbound_broadcast_presence
        broadcast(stream.available_resources(validate_to))
      end

      private
      def send_pending_stanzas
        return unless stream.prioritized?

        stream.background do
          loop do
            stanzas = storage.find_pending_stanzas!(stream.user.jid)
            break if stanzas.empty?

            stanzas.each do |stanza|
              node = Nokogiri::XML(stanza.xml).root rescue nil
              node['label'] = 'offline'

              if node.name == Vines::Stanza::MESSAGE
                Vines::Stanza.from_node(node, stream).archive!
              end

              stream.write(node)
            end
            storage.delete_pending_stanzas!(stanzas.map { |x| x.id })

            #sleep 0.5 # For large batches count very useful to slow down ...
          end
        end
      end

      def send_renew_messages
        # TODO : Write some stuff
      end

      def send_probe(to)
        to = JID.new(to)
        doc = Document.new
        probe = doc.create_element('presence',
          'from' => stream.user.jid.bare.to_s,
          'id'   => Kit.uuid,
          'to'   => to.bare.to_s,
          'type' => 'probe')
        router.route(probe) rescue nil # ignore RemoteServerNotFound
      end

      def auto_reply_to_subscription_request(from, type)
        doc = Document.new
        node = doc.create_element('presence') do |el|
          el['from'] = from.to_s
          el['id'] = self['id'] if self['id']
          el['to'] = stream.user.jid.bare.to_s
          el['type'] = type
        end
        stream.write(node)
      end

      # Send the contact's roster item to the current user's interested streams.
      # Roster pushes are required, following presence subscription updates, to
      # notify the user's clients of the contact's current state.
      def send_roster_push(to)
        contact = stream.user.contact(to)
        stream.interested_resources(stream.user.jid).each do |recipient|
          contact.send_roster_push(recipient)
        end
      end

      # Notify the current user's interested streams of a contact's subscription
      # state change as a result of receiving a subscribed, unsubscribe, or
      # unsubscribed presence stanza.
      def broadcast_subscription_change(contact)
        stamp_from
        stream.interested_resources(stamp_to).each do |recipient|
          @node['to'] = recipient.user.jid.to_s
          recipient.write(@node)
          contact.send_roster_push(recipient)
        end
      end

      # Validate that the incoming stanza has a 'to' attribute and strip any
      # resource part from it so it's a bare jid. Return the bare JID object
      # that was stamped.
      def stamp_to
        to = validate_to
        raise StanzaErrors::BadRequest.new(self, 'modify') unless to
        to.bare.tap do |bare|
          self['to'] = bare.to_s
        end
      end

      # Presence subscription stanzas must be addressed from the user's bare
      # JID. Return the user's bare JID object that was stamped.
      def stamp_from
        stream.user.jid.bare.tap do |bare|
          self['from'] = bare.to_s
        end
      end
    end
  end
end
