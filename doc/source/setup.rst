=============================
Ryuマルチノードシステムテスト
=============================

インストール & セットアップ
===========================

パッケージのインストール
------------------------

::

    $ sudo apt-get install jenkins git kvm libvirt-bin bridge-utils

テストの実行はJenkinsによって行います。

gitパッケージは、テスト用スクリプト類の取得のために必要となります。
kvm、bridge-utilsは、テスト環境構築のために使用します。


sudo
----

Jenkinsはユーザjenkinsで実行されます。Jenkinsから起動されるテストスクリプトも
同ユーザで実行されるので、jenkinsが、sudoをパスワードなしで実行できるように
設定します。

::

    $ sudo visudo
    jenkins   ALL=(ALL:ALL) NOPASSWD:ALL


SSH/git
-------

jenkinsユーザがssh、gitコマンドを実行できるようにします。

::

    $ cd /var/lib/jenkins
    $ sudo mkdir .ssh
    $ sudo vi .gitconfig
    [user]
            name = Ryu Network Operating System
            email = <mail address>
    $ sudo chown jenkins.jenkins .ssh .gitconfig


テスト環境の構築
----------------

/opt/ryu-devstack-it/にテスト環境を構築します。

::

    $ cd /opt
    $ sudo git clone https://github.com/ykaneko/ryu-devstack-it
    $ sudo chown -R jenkins.jenkins ryu-devstack-it

::

    ryu-devstack-it
    |-- doc                 ... ドキュメント
    |-- files
    |   |-- devstack        ... 各ターゲット用のlocalrcとlocal.confファイル
    |   |   |-- local.conf.icehouse-ofa-gre
    |   |   |-- local.conf.icehouse-ofa-vlan
    |   |   |-- local.conf.icehouse-ofa-vxlan
    |   |   |-- local.conf.master-ofa-gre
    |   |   |-- local.conf.master-ofa-vlan
    |   |   |-- local.conf.master-ofa-vxlan
    |   |   |-- localrc.havana-ryu-gre
    |   |   |-- localrc.havana-ryu-vlan
    |   |   |-- localrc.icehouse-ofa-gre
    |   |   |-- localrc.icehouse-ofa-vlan
    |   |   |-- localrc.icehouse-ofa-vxlan
    |   |   |-- localrc.icehouse-ryu-gre
    |   |   |-- localrc.icehouse-ryu-vlan
    |   |   |-- localrc.master-ofa-gre
    |   |   |-- localrc.master-ofa-vlan
    |   |   `-- localrc.master-ofa-vxlan
    |   |-- id_rsa          ... テストVM用sshキー
    |   `-- id_rsa.pub      ...   〃
    |-- ifdown              ... テストVM用ネットワーク設定スクリプト
    |-- ifdown2             ...   〃
    |-- ifup                ...   〃
    |-- ifup2               ...   〃
    `-- run.sh              ... テストスクリプト

テストスクリプトを実行すると以下のファイルが追加されます。

::

    |-- logs
    |   |-- devstack.havana-ryu-gre
    |   |   |-- ryudev1                         ... ryudev1のログ
    |   |   |   |-- devstack                    ... devstackのログ
    |   |   |   |-- devstack.2014-04-30-080045
    |   |   |   |-- devstack.summary            ... devstackのサマリ
    |   |   |   |-- devstack.2014-04-30-082158.2014-04-30-082158.summary
    |   |   |   `-- stack                       ... SCREENのログ
    |   |   |       |-- screen-c-api.2014-04-30-080045.log.gz
    |   |   |       |-- screen-c-api.log
                      <略>
    |   |   |       |-- screen-ryu.2014-04-30-080045.log.gz
    |   |   |       `-- screen-ryu.log
    |   |   |-- ryudev2
    |   |   `-- ryudev3
              <略>
    |   |-- log.havana-ryu-gre.20140430162730   ... テストスクリプトのログ
    |   `-- summary.havana-ryu-gre.20140430162730  ... テストスクリプトのサマリ
    |                                                  (標準出力の内容)
    |-- ryu1.havana-ryu-gre.qcow2               ... ryudev1のディスクイメージ
    |-- ryu2.havana-ryu-gre.qcow2               ... ryudev2のディスクイメージ
    |-- ryu3.havana-ryu-gre.qcow2               ... ryudev3のディスクイメージ
    `-- tmp
        |-- dnsmasq.log                         ... ホスト上のdnsmasqのログ
        |-- dnsmasq.lease                       ... dnsmasqのleaseファイル
        |-- dnsmasq.pid                         ... dnsmasqのpid
        |-- fixedip-vm1                         ... テストスクリプトで起動した
                                                    instanceのFixed-IP
        |-- fixedip-vm2
        |-- fixedip-vm3
        |-- fixedip-vm4
        |-- fixedip-vm5
        |-- floatingip-vm1                      ... テストスクリプトで起動した
                                                    instanceのFloating-IP
        |-- floatingip-vm2
        |-- floatingip-vm3
        |-- floatingip-vm4
        |-- floatingip-vm5
        |-- key1                                ... KeyPair
        |-- key2
        |-- key3
        |-- kvm_ryudev1.pid                     ... ryudev1のKVMのpid
        |-- kvm_ryudev2.pid
        `-- kvm_ryudev3.pid


Jenkinsの設定
=============

Jenkinsの設定はWeb画面で行います。

ブラウザで次のURLにアクセスします。

::

    http://HOST:8080/jenkins/


基本設定
--------

本テストは、1つのテスト環境を複数のテストで使用するため、同時に実行される
テストは1つのみに制限します。他のテストが実行中であった場合は、そのテストが
完了するまで待たされます。

- Jenkinsの管理 ≫ システムの設定

  - 同時ビルド数: 1

  - Email通知

    - SMTPサーバー: メールサーバ

    - 管理者のメールアドレス: <通知メールのFromアドレス>

  - 画面下の"保存"をクリックして保存します。


URLTrigger Pluginの追加
-----------------------

githubのcommitのRSSが更新されたときにテストを実行するため、URLTrigger Plugin
を使用します。

- Jenkinsの管理 ≫ プラグインの管理 ≫ 利用可能

  - URLTrigger Plugin にチェックを付ける

  - 画面下の"インストール"をクリックしてインストールします。

  - インストール画面の
    ``インストール完了後、ジョブがなければJenkinsを再起動する``
    にチェックを付け、インストール後にJenkinsを再起動するようにします。


ジョブの設定
------------

- 新規ジョブ作成
    - ジョブ名: havana-ryu-gre
    - フリースタイル・プロジェクトのビルド
    - 古いビルドの破棄
        - 方針: Log Rotation
            - ビルドの保持日数: 30

    - プロジェクトの高度な設定オプション
        - カスタムワークスペースの使用
        - ディレクトリ: /opt/ryu-devstack-it/

    - ソースコード管理システム
        - なし

    - ビルド・トリガ
        ::

            [URLTrigger] - Poll with a URL
              URL: https://github.com/osrg/ryu/commits/master.atom
              URL Response Check
                Inspect URL content
                
              URL: https://github.com/openstack/neutron/commits/stable/havana.atom
              URL Response Check
                Inspect URL content
                
              URL: https://github.com/openstack/nova/commits/stable/havana.atom
              URL Response Check
                Inspect URL content

        - Schedule
            ::

                H/30 * * * *

    - ビルド
        - シェルの実行
            - シェルスクリプト::

                #!/bin/bash
                rm -rf ./logs
                ./run.sh havana-ryu-gre

            ※ run.shは環境変数EXTIF(デフォルトeth0)を参照します。
            インターネットへの経路に使用するインターフェースの名前が
            eth0以外のときは明示的に指定してください。

            例. EXTIF=em1 ./run.sh havana-ryu-gre

    - ビルド後の処理  (必要に応じて設定します)
        - Email通知
            - 宛先: <宛先メールアドレス>
            - 不安定ビルドも逐一メールを送信

    - 画面下の"保存"をクリックしてジョブを登録します。


以下のジョブも同様にして作ります。ビルド・トリガのURLとビルドのシェル
スクリプトが若干違うだけです。

- havana-ryu-vlan
- icehouse-ryu-gre
- icehouse-ryu-vlan
- icehouse-ofa-gre
- icehouse-ofa-vlan
- icehouse-ofa-vxlan
- master-ofa-gre
- master-ofa-vlan
- master-ofa-vxlan


各々のビルド・トリガのURLとシェルスクリプトの設定内容は以下の通りです。

- havana-ryu-vlan
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/neutron/commits/stable/havana.atom
            URL: https://github.com/openstack/nova/commits/stable/havana.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh havana-ryu-vlan

- icehouse-ryu-gre
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/stable/icehouse.atom
            URL: https://github.com/openstack/nova/commits/stable/icehouse.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh icehouse-ryu-gre

- icehouse-ryu-vlan
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/stable/icehouse.atom
            URL: https://github.com/openstack/nova/commits/stable/icehouse.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh icehouse-ryu-vlan

- icehouse-ofa-gre
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/stable/icehouse.atom
            URL: https://github.com/openstack/nova/commits/stable/icehouse.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh icehouse-ofa-gre

- icehouse-ofa-vlan
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/stable/icehouse.atom
            URL: https://github.com/openstack/nova/commits/stable/icehouse.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh icehouse-ofa-vlan

- icehouse-ofa-vxlan
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/stable/icehouse.atom
            URL: https://github.com/openstack/nova/commits/stable/icehouse.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh icehouse-ofa-vxlan

- master-ofa-gre
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/master.atom
            URL: https://github.com/openstack/nova/commits/master.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh master-ofa-gre

- master-ofa-vlan
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/master.atom
            URL: https://github.com/openstack/nova/commits/master.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh master-ofa-vlan

- master-ofa-vxlan
    - ビルド・トリガ
        - [URLTrigger] - Poll with a URL::

            URL: https://github.com/osrg/ryu/commits/master.atom
            URL: https://github.com/openstack/quantum/commits/master.atom
            URL: https://github.com/openstack/nova/commits/master.atom

    - ビルド
        - シェルスクリプト::

            #!/bin/bash
            rm -rf ./logs
            ./run.sh master-ofa-vxlan
