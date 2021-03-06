/*
  Copyright (C) 2014 Mikael Hermansson
  Contact: Mikael Hermansson <mike@7b4.se>
  All rights reserved.
*/

import QtQuick 2.0
import QtQuick.LocalStorage 2.0
import Sailfish.Silica 1.0
import "pages"
ApplicationWindow
{
    id: app
    initialPage: Component { FirstPage { } }
    cover: Qt.resolvedUrl("cover/CoverPage.qml")

    signal transactionsUpdated

    property bool hideIncome: false
    property int latestMonths: 3
    property string defaultCurrency: Qt.locale().name
    property string errorText: ""
    onErrorTextChanged: { timerHot.start(); hot.opacity = 1.0; }

    Timer {
        id: timerHot
        repeat: false
        interval: 3000
        running: false
        onTriggered: hot.opacity = 0.0
    }

    QtObject{
        id: db
        property var _db: undefined
        function setup()
        {            
            createdb(false)
            if (!load())
            {
                console.log("recreate settingsdb")
                createdb(true)
                load()
            }
        }

        function createdb(force)
        {
            if (_db == undefined)
                _db = LocalStorage.openDatabaseSync("MyMoneyDB", "1.0", "Settings for MyMoney", 1000);

            _db.transaction(
                            function(tx) {
                                tx.executeSql('DROP TABLE IF EXISTS Settings;');
                            }
                        )

            _db.transaction(
                        function(tx) {
                            tx.executeSql('CREATE TABLE IF NOT EXISTS Map(key TEXT, value TEXT)');
                        }
                    )
        }


        function load()
        {
            try {
                _db.transaction(function(tx)
                {
                    var rs = tx.executeSql('SELECT value FROM Map WHERE key="transactionsLatestMonths";');
                    if(rs.rows.length)
                    {
                        latestMonths = rs.rows.item(0).value
                    }
                });
                _db.transaction(function(tx)
                {
                    var rs = tx.executeSql('SELECT value FROM Map WHERE key="hideIncome";');
                    if(rs.rows.length)
                    {
                        hideIncome = rs.rows.item(0).value
                    }
                });
                _db.transaction(function(tx)
                {
                    var rs = tx.executeSql('SELECT value FROM Map WHERE key="defaultCurrency";');
                    if(rs.rows.length)
                    {
                        defaultCurrency = rs.rows.item(0).value
                    }
                });
            }
            catch (e)
            {
                console.log(e)
                jsonloader.defaultCurrency = defaultCurrency
                return false
            }

            return true
        }

        function save()
        {
            _db.transaction(function(tx)
            {
                tx.executeSql('DELETE FROM Map;') // FIXME REPLACE INTO SEEMS NOT WORK
                tx.executeSql('INSERT OR REPLACE INTO Map VALUES (?,?);',["transactionsLatestMonths", latestMonths])
                tx.executeSql('INSERT OR REPLACE INTO Map VALUES (?,?);',["defaultCurrency", defaultCurrency])
                tx.executeSql('INSERT OR REPLACE INTO Map VALUES (?,?);',["hideIncome", hideIncome])
            });

            // special case jsonloader has no access to QML atm...
            // so we need to feed
            jsonloader.defaultCurrency = defaultCurrency
        }
    }

    Connections
    {
        target: jsonloader
        onError: error
    }

    Connections
    {
        target: transactionmanager
        onError: error
    }

    ListModel
    {
        id: modelAccountTypes
        function load(jsonCat)
        {
            for (var key in jsonCat)
            {
                modelAccountTypes.append({"group" : jsonCat[key].group, "type" : jsonCat[key].type})
            }
        }

        function lookupIndex(typ)
        {
            var index = 0;
            for (;index < modelAccountTypes.count; index++)
            {
                var str = modelAccountTypes.get(index).type;
                if (str.substr(1, str.length) == typ)
                    return index;
            }
            return -1;
        }
    }

    ListModel {
        id: modelAccountGroups
        function load(jsonCat)
        {
            for (var key in jsonCat)
            {
                modelAccountGroups.append({"title" : jsonCat[key], "id" : key})
            }
        }

        function lookupIndex(key)
        {
            var index = 0;
            for (;index < modelAccountGroups.count; index++)
            {
                var o = modelAccountGroups.get(index);
                if (o.id == key)
                    return index;
            }
            return -1;
        }
    }

    QtObject
    {
        id: modelTransactions

        property var transactions
        function load(jsonObject)
        {
            modelTransactions.transactions = jsonObject
        }

        function changeSaldos(trmd5, sum)
        {
            var o
            var tr = modelTransactions.transactions
            for (var key in tr)
            {
                if (key == trmd5)
                {
                    o = tr[key]  // o == transaction
                    break
                }
            }
            if (o)
            {
                var o2 = modelAccounts.lookupByMd5(o.from)
                o2.sum = o2.sum + o.sum
                if (o2.currency == defaultCurrency)
                    modelAccounts.updateTotal(o.group, o.sum)

                o2 = modelAccounts.lookupByMd5(o.to)
                o2.sum = o2.sum - o.sum
                if (o2.currency == defaultCurrency)
                    modelAccounts.updateTotal(o2.group, (o.sum * -1))
            }
            else
                console.log("CRITICAL==================================")
        }

        function add(transactionmd5, from, to, description, sum)
        {
            if (transactionmd5 != "")
                changeSaldos(transactionmd5)

            transactionmanager.add(transactionmd5, from, to, description, sum, true)
            modelTransactions.transactions = JSON.parse(jsonloader.dump()).transactions
            var o = modelAccounts.lookupByMd5(from)
            o.sum = o.sum - sum
            if (o.currency == defaultCurrency)
                modelAccounts.updateTotal(o.group, (sum * -1))

            o = modelAccounts.lookupByMd5(to)
            o.sum = o.sum + sum
            if (o.currency == defaultCurrency)
                modelAccounts.updateTotal(o.group, sum)

            transactionsUpdated()
        }
    }

    QtObject{ id: balanceAccount; property string md5; property string group; property string title; property string type; property double sum; property string locale: defaultCurrency; }
    ListModel
    {
        id: modelAccounts
        signal accountUpdated
        property double saldoIncomes: 0.0
        property double saldoBanks: 0.0
        property double saldoExpenses: 0.0

        function reload()
        {
            var jsonObject = JSON.parse(jsonloader.dump())
            load(jsonObject.accounts)
        }
        function load(jsonObject)
        {
            saldoIncomes = 0.0
            saldoBanks = 0.0
            saldoExpenses = 0.0
            modelAccounts.clear()
            for (var key in jsonObject)
            {
                var arr = jsonObject[key]
                if (arr["group"] != "SB")  // don't show balance account
                {
                    var currency = arr["currency"] ? arr["currency"] : defaultCurrency
                    add(arr["group"], arr["title"], arr["type"], arr["sum"], currency, key)
                }
                else
                {
                    balanceAccount.title = arr["title"]
                    balanceAccount.sum = arr["sum"]
                    balanceAccount.group = arr["group"]
                    balanceAccount.type = arr["type"]
                    balanceAccount.md5 = key
                }
            }

            accountUpdated()
        }

        function updateTotal(group, sum)
        {
            if (group == "0")
                saldoIncomes = saldoIncomes + sum
            else if (group == "1")
                saldoBanks = saldoBanks + sum
            else if (group == "2")
                saldoExpenses = saldoExpenses + sum

        }

        function getAccountSaldoAsString(md5)
        {
            var o = lookupByMd5(md5)

            return o ?  o.sum.toLocaleCurrencyString(Qt.locale(o.currency)) : ""
        }

        function add(group, title, typ, sum, currency, md)
        {
            var d = new Date()
            if (currency == defaultCurrency)
                updateTotal(group, sum)
            var o = {"md5" : md, "group": group, "type" : typ, "title" : title, "sum" : sum, "currency" : currency}
            for (var i = 0; i < modelAccounts.count; i++)
            {
                if (modelAccounts.get(i).group.localeCompare(group) >= 0)
                {
                    modelAccounts.insert(i, o)
                    break;
                }
            }

            if (i == modelAccounts.count)
                modelAccounts.append(o)

        }


        function lookupByMd5(_md5)
        {
            if (_md5 == "")
                return undefined

            if (_md5 == balanceAccount.md5)
                return balanceAccount

            for (var index = 0;index < modelAccounts.count; index++)
            {
                var o = modelAccounts.get(index)
               // console.log(_md5+" == "+o.md5)
                if (o.md5 == _md5)
                    return o;
            }

            return undefined;
        }

        function addOrChange(group, title, typ, sum, currency, _md5)
        {
            var jsonObject
            var o = lookupByMd5(_md5);
            if (!o) // new
            {
                // yes, notice addAcount will add new balancqa transaction...
                _md5 = jsonloader.addAccount(title, group, typ, sum, currency, "")
                // ... as we do it on transactions
                jsonObject = JSON.parse(jsonloader.dump())
                // reread transaction table since we have inserted new balance transaction
                modelTransactions.transactions = jsonObject.transactions
                // reread accounts...
                modelAccounts.load(jsonObject.accounts)
            }
            else
            {
/*
                // has currency changed
                if (o.currency == currency) // if currency has not changed no point reload just change model direcly
                {
                    o.group = group
                    o.title = title
                    o.type = typ
                    // but we have to save it in json file to...
                    jsonloader.addAccount(title, group, typ, sum, currency, _md5)
                    // ...and tell filter model (in FirstPage) we have updated accountModel (eg reread saldos)...
                    accountUpdated()
                }
                else // currency has changed we have to reload account model(s) so that totalsaldo gets updated correcly..
*/
                {
                    // store change...
                    jsonloader.addAccount(title, group, typ, sum, currency, _md5)
                    // fully reread json file..
                    jsonObject = JSON.parse(jsonloader.dump())
                    modelTransactions.transactions = jsonObject.transactions
                    modelAccounts.load(jsonObject.accounts)
                    // no point call accountUpdated here since load will do it...
                    transactionsUpdated() // tr updated if saldo changed...
                }
            }
        }
    }


    Rectangle {
        id: hot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Theme.itemSizeLarge
        color: Theme.highlightColor
        opacity: 0.0
        z: 1
        Label {
            anchors.centerIn: parent
            text: errorText
        }
    }

    Component.onCompleted: {
        db.setup()
        var txt = jsonloader.load()
        console.log(defaultCurrency)
        var jsonObject = JSON.parse(txt)
        modelAccountGroups.load(jsonObject.accountgroups)
        modelAccountTypes.load(jsonObject.accounttypes)
        modelAccounts.load(jsonObject.accounts)
        modelTransactions.load(jsonObject.transactions)
    }
}


