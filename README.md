1. Copy tron folder to lib folder
2. add " Peatio::Blockchain.registry[:tron] = Tron::Blockchain " to /config/initializers/blockchain_api.rb
3. add " Peatio::Wallet.registry[:tronid] = Tron::Wallet " to /config/initializers/wallet_api.rb