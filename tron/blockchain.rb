require "peatio/tron/concerns/encryption"

module Tron
  class Blockchain < Peatio::Blockchain::Abstract
    include Encryption

    DEFAULT_FEATURES = { case_sensitive: true, cash_addr_format: false }.freeze
    TOKEN_EVENT_IDENTIFIER = 'ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'

    def initialize(custom_features = {})
      @features = DEFAULT_FEATURES.merge(custom_features).slice(*SUPPORTED_FEATURES)
      @settings = {}
    end

    def configure(settings = {})
      # Clean client state during configure.
      @client = nil

      @trc10 = []; @trc20 = []; @trx = []

      @settings.merge!(settings.slice(*SUPPORTED_SETTINGS))
      @settings[:currencies]&.each do |c|
        if c.dig(:options, :trc10_token_id).present?
          @trc10 << c
        elsif c.dig(:options, :trc20_contract_address).present?
          @trc20 << c
        else
          @trx << c
        end
      end
    end

    def fetch_block!(block_number)
      client.json_rpc(path: 'wallet/getblockbynum', params: { num: block_number })
            .fetch('transactions', []).each_with_object([]) do |tx, txs_array|

        if %w[TransferContract TransferAssetContract].include? tx.dig('raw_data', 'contract')[0].fetch('type', nil)
          next if invalid_transaction?(tx)
        else
          tx = client.json_rpc(path: 'wallet/gettransactioninfobyid', params: { value: tx['txID'] })
          next if tx.nil? || invalid_trc20_transaction?(tx)
        end

        txs = build_transaction(tx.merge('block_number' => block_number)).map do |ntx|
          Peatio::Transaction.new(ntx)
        end

        txs_array.append(*txs)
      end.yield_self { |txs_array| Peatio::Block.new(block_number, txs_array) }
    rescue Tron::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    def latest_block_number
      client.json_rpc(path: 'wallet/getblockbylatestnum', params: { num: 1 })
            .fetch('block')[0]['block_header']['raw_data']['number']
    rescue Tron::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    def load_balance_of_address!(address, currency_id)
      currency = @settings[:currencies].find { |c| c[:id] == currency_id.to_s }
      raise UndefinedCurrencyError unless currency

      if currency.dig(:options, :trc10_token_id).present?
        client.json_rpc(path: 'wallet/getaccount',
                        params: { address: reformat_decode_address(address) }
        ).fetch('assetV2', [])
              .find { |a| a['key'] == currency.dig(:options, :trc10_token_id) }
              .try(:fetch, 'value', 0)
      elsif currency.dig(:options, :trc20_contract_address).present?
        client.json_rpc(path: 'wallet/triggersmartcontract',
                        params: {
                          owner_address: reformat_decode_address(address),
                          contract_address: reformat_decode_address(currency.dig(:options, :trc20_contract_address)),
                          function_selector: 'balanceOf(address)',
                          parameter: abi_encode(reformat_decode_address(address)[2..42]) }
        ).fetch('constant_result')[0].hex
      else
        client.json_rpc(path: 'wallet/getaccount',
                        params: { address: reformat_decode_address(address) }
        ).fetch('balance', nil)
      end.yield_self { |amount| convert_from_base_unit(amount.to_i, currency) }
    rescue Tron::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    private

    def build_transaction(tx_hash)
      if tx_hash.has_key?('contract_address')
        build_trc20_transaction(tx_hash)
      else
        case tx_hash['raw_data']['contract'][0]['type']
        when 'TransferContract'
          build_coin_transaction(tx_hash)
        when 'TransferAssetContract'
          build_trc10_transaction(tx_hash)
        end
      end
    end

    def build_trc10_transaction(tx_hash)
      tx = tx_hash['raw_data']['contract'][0]
      currencies = @trc10.select do |c|
        c.dig(:options, :trc10_token_id) == decode_hex(tx['parameter']['value']['asset_name'])
      end

      formatted_txs = []
      currencies.each do |currency|
        formatted_txs << { hash: reformat_txid(tx_hash['txID']),
                           amount: convert_from_base_unit(tx['parameter']['value']['amount'], currency),
                           to_address: reformat_encode_address(tx['parameter']['value']['to_address']),
                           txout: 0,
                           block_number: tx_hash['block_number'],
                           currency_id: currency.fetch(:id),
                           status: 'success' }
      end
      formatted_txs
    end

    def build_trc20_transaction(tx_hash)
      # Build invalid transaction for failed withdrawals
      if trc20_transaction_status(tx_hash) == 'failed' && tx_hash.fetch('log', []).blank?
        return build_invalid_trc20_transaction(tx_hash)
      end

      formatted_txs = []
      tx_hash.fetch('log', []).each_with_index do |log, index|
        next if log.fetch('topics', []).blank? || log.fetch('topics')[0] != TOKEN_EVENT_IDENTIFIER

        # Skip if TRC20 contract address doesn't match.
        currencies = @trc20.select do |c|
          c.dig(:options, :trc20_contract_address) == reformat_encode_address("41#{log.fetch('address')}")
        end
        next if currencies.blank?

        destination_address = reformat_encode_address("41#{log.fetch('topics').last[-40..-1]}")

        currencies.each do |currency|
          formatted_txs << { hash: reformat_txid(tx_hash.fetch('id')),
                             amount: convert_from_base_unit(log.fetch('data').hex, currency),
                             to_address: destination_address,
                             txout: index,
                             block_number: tx_hash['block_number'],
                             currency_id: currency.fetch(:id),
                             status: trc20_transaction_status(tx_hash)
          }
        end
      end
      formatted_txs
    end

    def build_coin_transaction(tx_hash)
      tx = tx_hash['raw_data']['contract'][0]
      @trx.map do |currency|
        { hash: reformat_txid(tx_hash['txID']),
          amount: convert_from_base_unit(tx['parameter']['value']['amount'], currency),
          to_address: reformat_encode_address(tx['parameter']['value']['to_address']),
          txout: 0,
          block_number: tx_hash['block_number'],
          currency_id: currency.fetch(:id),
          status: 'success' }
      end
    end

    def build_invalid_trc20_transaction(tx_hash)
      currencies = @trc20.select do |c|
        c.dig(:options, :trc20_contract_address) == reformat_encode_address(tx_hash.fetch('contract_address'))
      end
      return [] if currencies.blank?

      currencies.each_with_object([]) do |currency, invalid_txs|
        invalid_txs << { hash: reformat_txid(tx_hash.fetch('txID')),
                         block_number: tx_hash.fetch('block_number'),
                         currency_id: currency.fetch(:id),
                         status: trc20_transaction_status(tx_hash) }
      end
    end

    def trc20_transaction_status(txn_hash)
      txn_hash['receipt']['result'] == 'SUCCESS' ? 'success' : 'failed'
    end

    def invalid_transaction?(tx)
      tx['raw_data']['contract'][0]['parameter']['value']['amount'].to_i == 0 \
         || tx['ret'][0]['contractRet'] == 'REVERT'
    end

    def invalid_trc20_transaction?(tx)
      tx.fetch('contract_address', '').blank? \
         || tx.fetch('log', []).blank?
    end

    def convert_from_base_unit(value, currency)
      value.to_d / currency.fetch(:base_factor).to_d
    end

    def client
      @client ||= Client.new(settings_fetch(:server))
    end

    def settings_fetch(key)
      @settings.fetch(key) { raise Peatio::Blockchain::MissingSettingError, key.to_s }
    end
  end
end