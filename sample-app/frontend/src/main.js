// 프론트엔드 hello world + 백엔드 호출 데모
document.getElementById('msg').textContent = 'Hello World from frontend';

// 같은 네임스페이스의 backend 서비스로 프록시(nginx /api/ → acme-app-backend:3000)
fetch('/api/hello')
  .then((r) => r.json())
  .then((d) => {
    document.getElementById('backend').textContent = `backend says: ${d.message} (env=${d.env})`;
  })
  .catch(() => {
    document.getElementById('backend').textContent = 'backend 연결 대기 중...';
  });
