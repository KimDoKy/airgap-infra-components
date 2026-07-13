// Jenkins 최초 기동 시 자동 실행됩니다 (scripts/03-start.sh 가 jenkins_home/init.groovy.d/ 로 복사).
// 브라우저 설치 마법사를 거치지 않고 CLI(무인)로 관리자 계정 및 기본 보안을 설정합니다.
// 컨테이너 environment 로 전달된 JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD 를 사용합니다.

import jenkins.model.*
import hudson.security.*

def env = System.getenv()
def adminId = env['JENKINS_ADMIN_ID'] ?: 'admin'
def adminPassword = env['JENKINS_ADMIN_PASSWORD'] ?: 'admin'

def instance = Jenkins.get()

if (!(instance.getSecurityRealm() instanceof HudsonPrivateSecurityRealm)) {
    def realm = new HudsonPrivateSecurityRealm(false)
    realm.createAccount(adminId, adminPassword)
    instance.setSecurityRealm(realm)

    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    strategy.setAllowAnonymousRead(false)
    instance.setAuthorizationStrategy(strategy)

    instance.save()
    println "-- init.groovy.d: 관리자 계정(${adminId})을 생성하고 보안을 설정했습니다."
} else {
    println "-- init.groovy.d: 보안 realm이 이미 설정되어 있어 건너뜁니다."
}
